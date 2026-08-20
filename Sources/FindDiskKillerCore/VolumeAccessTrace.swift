import Foundation

public enum VolumeAccessTraceOperationCategory: Equatable, Sendable {
    case metadata
    case read
    case write
}

public struct VolumeAccessTraceParsedEvent: Equatable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let fileDescriptor: Int32?
    public let path: String?
    public let pathWasTruncated: Bool
    public let processLabel: String
    public let threadID: UInt64
}

public enum VolumeAccessTraceLineResult: Equatable, Sendable {
    case event(VolumeAccessTraceParsedEvent)
    case ignored
    case failedCall
    case unsupportedFormat
}

public enum VolumeAccessTraceParser {
    private static let readCalls: Set<String> = [
        "read", "pread", "readv", "preadv",
        "read_nocancel", "pread_nocancel", "readv_nocancel", "preadv_nocancel",
        "rddata", "rddata_nocancel"
    ]
    private static let writeCalls: Set<String> = [
        "write", "pwrite", "writev", "pwritev",
        "write_nocancel", "pwrite_nocancel", "writev_nocancel", "pwritev_nocancel",
        "wrdata", "wrdata_nocancel"
    ]
    private static let metadataCalls: Set<String> = [
        "access", "eaccess", "faccessat", "fsgetpath",
        "getattrlist", "getattrlistat", "getattrlistbulk",
        "getdirentries", "getdirentries64", "getxattr", "listxattr",
        "lstat", "lstat64", "open", "open_nocancel", "openat", "openat_nocancel",
        "readlink", "readlinkat", "searchfs", "stat", "stat64", "statfs",
        "rdmeta", "wrmeta", "rdmetacs", "wrmetacs"
    ]

    public static func parse(
        line: String,
        on day: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> VolumeAccessTraceLineResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        if FileAccessTraceParser.recognizesHeader(trimmed) { return .ignored }

        let fields = trimmed.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard fields.count >= 4 else { return .ignored }
        guard let timestamp = parseTimestamp(fields[0], on: day, calendar: calendar) else {
            return fields[0].first?.isNumber == true ? .unsupportedFormat : .ignored
        }

        let operation = normalizedOperation(fields[1])
        let category: VolumeAccessTraceOperationCategory
        if readCalls.contains(operation) {
            category = .read
        } else if writeCalls.contains(operation) {
            category = .write
        } else if metadataCalls.contains(operation) {
            category = .metadata
        } else {
            return .ignored
        }

        if containsStandaloneErrno(fields: fields) { return .failedCall }

        let byteIndex = fields.firstIndex(where: { $0.hasPrefix("B=") })
        let requestedBytes = byteIndex.flatMap {
            parseUnsigned(String(fields[$0].dropFirst(2)))
        }
        // Some macOS releases omit B= for cache/metadata-adjacent rows. Keep
        // the path and process visible, but leave the byte count unknown rather
        // than treating one row as proof that the entire stream is unusable.

        let fileDescriptor = fields.first(where: { $0.hasPrefix("F=") })
            .flatMap { parseFileDescriptor(String($0.dropFirst(2))) }

        guard let durationIndex = fields.indices.reversed().first(where: {
                $0 > 1 && $0 < fields.count - 1 && isDuration(fields[$0])
              })
        else { return .ignored }

        let processField = fields[(durationIndex + 1)...]
            .filter { $0 != "W" }
            .joined(separator: " ")
        guard let process = parseProcessField(processField) else {
            return .ignored
        }

        let detailFields = fields[2..<durationIndex]
        let path = parsePath(from: Array(detailFields))

        return .event(VolumeAccessTraceParsedEvent(
            timestamp: timestamp,
            operation: operation,
            category: category,
            requestedBytes: requestedBytes,
            fileDescriptor: fileDescriptor,
            path: path.value,
            pathWasTruncated: path.wasTruncated,
            processLabel: process.label,
            threadID: process.threadID
        ))
    }

    private static func normalizedOperation(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        ).inverted).lowercased()
        // fs_usage annotates filesystem calls on some macOS releases, for
        // example `RdData[AT1]`. The annotation is not part of the operation
        // name used for aggregation.
        return trimmed.split(whereSeparator: { $0 == "[" || $0 == "(" || $0 == "<" })
            .first
            .map(String.init) ?? trimmed
    }

    private static func parseTimestamp(
        _ value: String,
        on day: Date,
        calendar: Calendar
    ) -> Date? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute)
        else { return nil }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2,
              let second = Int(secondParts[0]), (0...60).contains(second),
              !secondParts[1].isEmpty,
              secondParts[1].allSatisfy(\.isNumber),
              let fraction = Double("0." + secondParts[1])
        else { return nil }
        let start = calendar.startOfDay(for: day)
        guard let wholeSeconds = calendar.date(
            byAdding: .second,
            value: hour * 3_600 + minute * 60 + min(second, 59),
            to: start
        ) else { return nil }
        let candidate = wholeSeconds.addingTimeInterval(fraction + (second == 60 ? 1 : 0))
        let distance = candidate.timeIntervalSince(day)
        if distance > 12 * 60 * 60 {
            return calendar.date(byAdding: .day, value: -1, to: candidate)
        }
        if distance < -12 * 60 * 60 {
            return calendar.date(byAdding: .day, value: 1, to: candidate)
        }
        return candidate
    }

    private static func parsePath(from fields: [String]) -> (value: String?, wasTruncated: Bool) {
        guard let start = fields.firstIndex(where: {
            $0.hasPrefix("/") || $0.hasPrefix("private/")
                || $0.hasPrefix("...") || $0.hasPrefix("<truncated>")
        }) else {
            return (nil, false)
        }
        let pathFields = fields[start...].filter {
            !$0.hasPrefix("(") && $0 != "W" && !isMetadata($0)
        }
        var rawPath = pathFields.joined(separator: " ")
        if rawPath.hasPrefix("private/") {
            rawPath = "/" + rawPath
        }
        let wasTruncated = rawPath.hasPrefix("...") || rawPath.hasPrefix("<truncated>")
        return (!wasTruncated && rawPath.hasPrefix("/")) ? (rawPath, false) : (nil, wasTruncated)
    }

    private static func parseUnsigned(_ value: String) -> UInt64? {
        if value.lowercased().hasPrefix("0x") {
            return UInt64(value.dropFirst(2), radix: 16)
        }
        return UInt64(value)
    }

    private static func parseFileDescriptor(_ value: String) -> Int32? {
        guard let parsed = parseUnsigned(value), parsed <= UInt64(Int32.max) else { return nil }
        return Int32(parsed)
    }

    private static func containsStandaloneErrno(fields: [String]) -> Bool {
        guard fields.count > 2 else { return false }
        for index in 2..<fields.count where fields[index].hasPrefix("F=")
            || fields[index].hasPrefix("B=") {
            var candidate = fields[index]
            var nextIndex: Int
            if !candidate.contains("[") {
                guard index + 1 < fields.count,
                      fields[index + 1].hasPrefix("[")
                else { continue }
                candidate = fields[index + 1]
                nextIndex = index + 2
            } else {
                candidate = String(candidate[candidate.firstIndex(of: "[")!...])
                nextIndex = index + 1
            }
            while !candidate.contains("]"), nextIndex < fields.count,
                  nextIndex <= index + 2 {
                candidate += " " + fields[nextIndex]
                nextIndex += 1
            }
            guard candidate.first == "[", candidate.last == "]" else { continue }
            let code = candidate.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces)
            if !code.isEmpty, code.allSatisfy(\.isNumber) {
                return true
            }
        }
        return false
    }

    private static func parseProcessField(_ value: String) -> (label: String, threadID: UInt64)? {
        guard let separator = value.lastIndex(of: "."),
              separator != value.startIndex,
              let threadID = UInt64(value[value.index(after: separator)...])
        else { return nil }
        return (String(value[..<separator]), threadID)
    }

    private static func isDuration(_ value: String) -> Bool {
        let candidate = value.hasSuffix("W") ? String(value.dropLast()) : value
        return candidate.contains(".") && Double(candidate) != nil
    }

    private static func isMetadata(_ value: String) -> Bool {
        if ["A=", "B=", "D=", "F=", "O=", "S="].contains(where: { value.hasPrefix($0) }) {
            return true
        }
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
            return false
        }
        return value[..<equals].allSatisfy { $0.isASCII && $0.isUppercase }
    }
}

public struct VolumeAccessTraceScope: Equatable, Sendable {
    public let path: String
    public let mountPath: String
    public let isCaseSensitive: Bool
    fileprivate let includesAncestorDirectories: Bool

    public init(
        path: String,
        mountPath: String,
        isCaseSensitive: Bool = true,
        includesAncestorDirectories: Bool = true
    ) {
        self.path = VolumeAccessTraceTarget.canonicalPath(path)
        self.mountPath = VolumeAccessTraceTarget.canonicalPath(mountPath)
        self.isCaseSensitive = isCaseSensitive
        self.includesAncestorDirectories = includesAncestorDirectories
    }

    fileprivate func contains(_ candidate: String) -> Bool {
        if VolumeAccessTraceTarget.pathsEqual(
            path,
            "/",
            caseSensitive: isCaseSensitive
        ), mountPath == "/" {
            return VolumeAccessTraceTarget.belongsToStartupVolume(candidate)
        }
        if VolumeAccessTraceTarget.pathsEqual(
            candidate,
            path,
            caseSensitive: isCaseSensitive
        ) {
            return true
        }
        let prefix = path == "/" ? "/" : path + "/"
        return candidate.count > path.count && (isCaseSensitive
            ? candidate.hasPrefix(prefix)
            : candidate.lowercased().hasPrefix(prefix.lowercased()))
    }
}

public struct VolumeAccessTraceTarget: Equatable, Sendable {
    public let volumeID: String
    public let name: String
    public let mountPath: String
    public let scopePath: String
    public let isCaseSensitive: Bool
    public let scopes: [VolumeAccessTraceScope]

    public init(
        volumeID: String,
        name: String,
        mountPath: String,
        isCaseSensitive: Bool = true,
        scopePath: String? = nil
    ) {
        let canonicalMountPath = Self.canonicalPath(mountPath)
        let canonicalScopePath = Self.canonicalPath(scopePath ?? mountPath)
        self.init(
            volumeID: volumeID,
            name: name,
            scopes: [VolumeAccessTraceScope(
                path: canonicalScopePath,
                mountPath: canonicalMountPath,
                isCaseSensitive: isCaseSensitive,
                includesAncestorDirectories: scopePath != nil
            )]
        )
    }

    public init(
        volumeID: String,
        name: String,
        scopes: [VolumeAccessTraceScope]
    ) {
        precondition(!scopes.isEmpty, "A volume access target requires at least one scope")
        self.volumeID = volumeID
        self.name = name
        self.scopes = scopes
        self.mountPath = scopes[0].mountPath
        self.scopePath = scopes[0].path
        self.isCaseSensitive = scopes[0].isCaseSensitive
    }

    public init(
        volume: VolumeInfo,
        isCaseSensitive: Bool = true,
        scopePath: String? = nil
    ) {
        self.init(
            volumeID: volume.id,
            name: volume.name,
            mountPath: volume.mountPath,
            isCaseSensitive: isCaseSensitive,
            scopePath: scopePath
        )
    }

    public func contains(path: String) -> Bool {
        let candidate = Self.canonicalPath(path)
        return scopes.contains { $0.contains(candidate) }
    }

    func directoryAncestors(for path: String) -> [String] {
        let canonicalPath = Self.canonicalPath(path)
        guard let scope = matchingScope(for: canonicalPath) else { return [] }
        var current = URL(fileURLWithPath: canonicalPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        var result: [String] = [current]

        guard scope.includesAncestorDirectories else { return result }

        while scope.contains(current) {
            if Self.pathsEqual(current, scope.path, caseSensitive: scope.isCaseSensitive) {
                break
            }
            let parent = URL(fileURLWithPath: current)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            guard parent != current else { break }
            current = parent
            result.append(current)
        }
        return result
    }

    private func matchingScope(for canonicalPath: String) -> VolumeAccessTraceScope? {
        scopes
            .filter { $0.contains(canonicalPath) }
            .max { $0.path.count < $1.path.count }
    }

    /// fs_usage can report an APFS Data-volume path through either the public
    /// mount (`/Users`, `/private`, `/Volumes`, ...) or its backing
    /// `/System/Volumes/Data/...` alias. Resolve real symlinks first, then
    /// apply the stable mount alias even when the file has already disappeared
    /// by the time the event is aggregated.
    public static func canonicalPath(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let dataVolumesPrefix = "/System/Volumes/Data/Volumes/"
        if resolved.hasPrefix(dataVolumesPrefix) {
            return "/Volumes/" + resolved.dropFirst(dataVolumesPrefix.count)
        }
        if resolved == "/System/Volumes/Data/Volumes" {
            return "/Volumes"
        }
        let startupDataPrefix = "/System/Volumes/Data/"
        if resolved.hasPrefix(startupDataPrefix) {
            return "/" + resolved.dropFirst(startupDataPrefix.count)
        }
        if resolved == "/System/Volumes/Data" {
            return "/"
        }
        return resolved
    }

    fileprivate static func belongsToStartupVolume(_ path: String) -> Bool {
        guard path != "/" else { return true }
        let excludedPrefixes = [
            "/Volumes/",
            "/System/Volumes/Preboot/",
            "/System/Volumes/VM/",
            "/System/Volumes/Update/"
        ]
        return !excludedPrefixes.contains { path.hasPrefix($0) }
    }

    fileprivate static func pathsEqual(
        _ lhs: String,
        _ rhs: String,
        caseSensitive: Bool
    ) -> Bool {
        caseSensitive ? lhs == rhs : lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

public struct VolumeAccessTraceProcessReference: Hashable, Sendable {
    public let pid: Int32?
    public let startAbstime: UInt64?
    public let displayName: String

    public init(pid: Int32?, startAbstime: UInt64?, displayName: String) {
        self.pid = pid
        self.startAbstime = startAbstime
        self.displayName = displayName
    }

    public var stableID: String {
        if let pid, let startAbstime {
            return "\(pid):\(startAbstime)"
        }
        return "label:\(displayName)"
    }
}

public struct VolumeAccessTraceEvent: Equatable, Sendable {
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let path: String
    public let process: VolumeAccessTraceProcessReference

    public init(
        timestamp: Date,
        operation: String,
        category: VolumeAccessTraceOperationCategory,
        requestedBytes: UInt64?,
        path: String,
        process: VolumeAccessTraceProcessReference
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.category = category
        self.requestedBytes = requestedBytes
        self.path = path
        self.process = process
    }
}

public struct VolumeAccessTraceSourceSummary: Identifiable, Equatable, Sendable {
    public let process: VolumeAccessTraceProcessReference
    public let firstEventAt: Date
    public let lastEventAt: Date
    public let firstOperation: String
    public let samplePath: String
    public let metadataEventCount: Int
    public let readEventCount: Int
    public let writeEventCount: Int
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64

    public var id: String { process.stableID }
}

public struct VolumeAccessTraceDirectorySummary: Identifiable, Equatable, Sendable {
    public let path: String
    /// Requested I/O whose event path is directly inside this directory.
    /// These mutually exclusive values are suitable for a flat Top ranking.
    public let requestedReadBytes: UInt64
    public let requestedWriteBytes: UInt64
    public let eventCount: Int
    public let lastEventAt: Date
    /// Requested I/O inside this directory or any descendant directory.
    /// These values intentionally overlap between ancestors and descendants
    /// and therefore belong in a directory detail, not a flat ranking.
    public let requestedReadBytesIncludingDescendants: UInt64
    public let requestedWriteBytesIncludingDescendants: UInt64
    public let eventCountIncludingDescendants: Int
    public let lastEventAtIncludingDescendants: Date

    public var id: String { path }
}

public struct VolumeAccessTraceEventSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let operation: String
    public let category: VolumeAccessTraceOperationCategory
    public let requestedBytes: UInt64?
    public let path: String
    public let process: VolumeAccessTraceProcessReference
}

public struct VolumeAccessTraceSnapshot: Equatable, Sendable {
    public let coverage: FileAccessTraceCoverage
    public let firstEventAt: Date?
    public let lastEventAt: Date?
    public let requestedReadBytes: UInt64?
    public let requestedWriteBytes: UInt64?
    public let metadataEventCount: Int?
    public let sources: [VolumeAccessTraceSourceSummary]
    public let directories: [VolumeAccessTraceDirectorySummary]
    public let events: [VolumeAccessTraceEventSummary]
}

public struct VolumeAccessTraceAggregator: Sendable {
    private struct SourceTotals: Sendable {
        var firstEventAt: Date?
        var lastEventAt: Date?
        var firstOperation = ""
        var samplePath = ""
        var metadataEvents = 0
        var readEvents = 0
        var writeEvents = 0
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
    }

    private struct DirectoryTotals: Sendable {
        var directReadBytes: UInt64 = 0
        var directWriteBytes: UInt64 = 0
        var directEventCount = 0
        var directLastEventAt: Date?
        var inclusiveReadBytes: UInt64 = 0
        var inclusiveWriteBytes: UInt64 = 0
        var inclusiveEventCount = 0
        var inclusiveLastEventAt: Date?
    }

    private let target: VolumeAccessTraceTarget
    private let startedAt: Date
    private let maximumSources: Int
    private let maximumEvents: Int
    private var readBytes: UInt64 = 0
    private var writeBytes: UInt64 = 0
    private var metadataEvents = 0
    private var firstEventAt: Date?
    private var lastEventAt: Date?
    private var sources: [VolumeAccessTraceProcessReference: SourceTotals] = [:]
    private var directories: [String: DirectoryTotals] = [:]
    private var events: [VolumeAccessTraceEventSummary] = []
    private var droppedEventCount: UInt64 = 0
    private var formatIsUnsupported = false

    public init(
        target: VolumeAccessTraceTarget,
        startedAt: Date,
        maximumSources: Int = 512,
        maximumEvents: Int = 240
    ) {
        self.target = target
        self.startedAt = startedAt
        self.maximumSources = max(1, maximumSources)
        self.maximumEvents = max(1, maximumEvents)
    }

    public mutating func ingest(_ event: VolumeAccessTraceEvent) {
        guard !formatIsUnsupported, event.timestamp >= startedAt else {
            markDroppedEvents()
            return
        }
        guard target.contains(path: event.path) else { return }
        let canonicalEventPath = VolumeAccessTraceTarget.canonicalPath(event.path)

        switch event.category {
        case .metadata:
            metadataEvents += 1
        case .read:
            guard let requestedBytes = event.requestedBytes,
                  let updated = adding(readBytes, requestedBytes)
            else {
                formatIsUnsupported = true
                return
            }
            readBytes = updated
        case .write:
            guard let requestedBytes = event.requestedBytes,
                  let updated = adding(writeBytes, requestedBytes)
            else {
                formatIsUnsupported = true
                return
            }
            writeBytes = updated
        }

        firstEventAt = min(firstEventAt ?? event.timestamp, event.timestamp)
        lastEventAt = max(lastEventAt ?? event.timestamp, event.timestamp)

        if event.category != .metadata {
            let directoryPaths = target.directoryAncestors(for: canonicalEventPath)
            let directDirectoryPath = directoryPaths.first
            for directoryPath in directoryPaths {
                var directory = directories[directoryPath, default: DirectoryTotals()]
                directory.inclusiveEventCount += 1
                directory.inclusiveLastEventAt = max(
                    directory.inclusiveLastEventAt ?? event.timestamp,
                    event.timestamp
                )
                if directoryPath == directDirectoryPath {
                    directory.directEventCount += 1
                    directory.directLastEventAt = max(
                        directory.directLastEventAt ?? event.timestamp,
                        event.timestamp
                    )
                }
                switch event.category {
                case .read:
                    if let bytes = event.requestedBytes {
                        guard let inclusive = adding(directory.inclusiveReadBytes, bytes) else {
                            formatIsUnsupported = true
                            return
                        }
                        directory.inclusiveReadBytes = inclusive
                        if directoryPath == directDirectoryPath {
                            guard let direct = adding(directory.directReadBytes, bytes) else {
                                formatIsUnsupported = true
                                return
                            }
                            directory.directReadBytes = direct
                        }
                    }
                case .write:
                    if let bytes = event.requestedBytes {
                        guard let inclusive = adding(directory.inclusiveWriteBytes, bytes) else {
                            formatIsUnsupported = true
                            return
                        }
                        directory.inclusiveWriteBytes = inclusive
                        if directoryPath == directDirectoryPath {
                            guard let direct = adding(directory.directWriteBytes, bytes) else {
                                formatIsUnsupported = true
                                return
                            }
                            directory.directWriteBytes = direct
                        }
                    }
                case .metadata:
                    break
                }
                directories[directoryPath] = directory
            }
        }

        if sources[event.process] == nil, sources.count >= maximumSources {
            markDroppedEvents()
        } else {
            var totals = sources[event.process, default: SourceTotals()]
            if totals.firstEventAt == nil || event.timestamp < totals.firstEventAt! {
                totals.firstEventAt = event.timestamp
                totals.firstOperation = event.operation
                totals.samplePath = canonicalEventPath
            }
            totals.lastEventAt = max(totals.lastEventAt ?? event.timestamp, event.timestamp)
            switch event.category {
            case .metadata:
                totals.metadataEvents += 1
            case .read:
                totals.readEvents += 1
                if let bytes = event.requestedBytes {
                    guard let updated = adding(totals.readBytes, bytes) else {
                        formatIsUnsupported = true
                        return
                    }
                    totals.readBytes = updated
                }
            case .write:
                totals.writeEvents += 1
                if let bytes = event.requestedBytes {
                    guard let updated = adding(totals.writeBytes, bytes) else {
                        formatIsUnsupported = true
                        return
                    }
                    totals.writeBytes = updated
                }
            }
            sources[event.process] = totals
        }

        if events.count < maximumEvents {
            events.append(VolumeAccessTraceEventSummary(
                id: "\(event.timestamp.timeIntervalSince1970):\(events.count)",
                timestamp: event.timestamp,
                operation: event.operation,
                category: event.category,
                requestedBytes: event.requestedBytes,
                path: canonicalEventPath,
                process: event.process
            ))
        } else {
            markDroppedEvents()
        }
    }

    public mutating func markDroppedEvents(_ count: UInt64 = 1) {
        droppedEventCount = adding(droppedEventCount, count) ?? UInt64.max
    }

    public mutating func markUnsupportedFormat() {
        formatIsUnsupported = true
    }

    public func snapshot() -> VolumeAccessTraceSnapshot {
        guard !formatIsUnsupported else {
            return VolumeAccessTraceSnapshot(
                coverage: .unsupportedFormat,
                firstEventAt: firstEventAt,
                lastEventAt: lastEventAt,
                requestedReadBytes: nil,
                requestedWriteBytes: nil,
                metadataEventCount: nil,
                sources: [],
                directories: [],
                events: []
            )
        }
        let coverage: FileAccessTraceCoverage = droppedEventCount == 0
            ? .complete
            : .partial(droppedEventCount: droppedEventCount)
        return VolumeAccessTraceSnapshot(
            coverage: coverage,
            firstEventAt: firstEventAt,
            lastEventAt: lastEventAt,
            requestedReadBytes: readBytes,
            requestedWriteBytes: writeBytes,
            metadataEventCount: metadataEvents,
            sources: sources.compactMap { process, totals in
                guard let first = totals.firstEventAt,
                      let last = totals.lastEventAt
                else { return nil }
                return VolumeAccessTraceSourceSummary(
                    process: process,
                    firstEventAt: first,
                    lastEventAt: last,
                    firstOperation: totals.firstOperation,
                    samplePath: totals.samplePath,
                    metadataEventCount: totals.metadataEvents,
                    readEventCount: totals.readEvents,
                    writeEventCount: totals.writeEvents,
                    requestedReadBytes: totals.readBytes,
                    requestedWriteBytes: totals.writeBytes
                )
            }.sorted {
                if $0.firstEventAt != $1.firstEventAt {
                    return $0.firstEventAt < $1.firstEventAt
                }
                return $0.process.displayName.localizedStandardCompare(
                    $1.process.displayName
                ) == .orderedAscending
            },
            directories: directories.compactMap { path, totals in
                // A flat Top list must be mutually exclusive. Ancestors that
                // only inherited descendant activity remain internal so they
                // can contribute to inclusive totals, but are not emitted as
                // independent ranked rows.
                guard let directLastEventAt = totals.directLastEventAt,
                      let inclusiveLastEventAt = totals.inclusiveLastEventAt
                else { return nil }
                return VolumeAccessTraceDirectorySummary(
                    path: path,
                    requestedReadBytes: totals.directReadBytes,
                    requestedWriteBytes: totals.directWriteBytes,
                    eventCount: totals.directEventCount,
                    lastEventAt: directLastEventAt,
                    requestedReadBytesIncludingDescendants: totals.inclusiveReadBytes,
                    requestedWriteBytesIncludingDescendants: totals.inclusiveWriteBytes,
                    eventCountIncludingDescendants: totals.inclusiveEventCount,
                    lastEventAtIncludingDescendants: inclusiveLastEventAt
                )
            }.sorted {
                ($0.requestedWriteBytes, $0.requestedReadBytes, $0.path)
                    > ($1.requestedWriteBytes, $1.requestedReadBytes, $1.path)
            },
            events: events.sorted { $0.timestamp < $1.timestamp }
        )
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
