import AppKit
import Charts
import FindDiskKillerCore
import FindDiskKillerTraceProtocol
import Observation
import SwiftUI

private enum DirectoryWorkspaceTab: String, CaseIterable, Identifiable {
    case top
    case guardRule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: L10n.text("读写 Top")
        case .guardRule: L10n.text("目录守护")
        }
    }
}

private enum DirectoryTopSort: String, CaseIterable, Identifiable {
    case write
    case read
    case events

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: L10n.text("写入优先")
        case .read: L10n.text("读取优先")
        case .events: L10n.text("事件")
        }
    }
}

enum DirectoryGuardOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case readWrite
    case read
    case write

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readWrite: L10n.text("读写")
        case .read: L10n.text("读取")
        case .write: L10n.text("写入")
        }
    }
}

struct DirectoryGuardRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var path: String
    var operation: DirectoryGuardOperation
    var expectedPrograms: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        path: String,
        operation: DirectoryGuardOperation = .readWrite,
        expectedPrograms: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.path = VolumeAccessTraceTarget.canonicalPath(path)
        self.operation = operation
        self.expectedPrograms = expectedPrograms
        self.isEnabled = isEnabled
    }

    var expectedProgramNames: [String] {
        Self.normalizedExpectedProgramNames(
            expectedPrograms.split(separator: ",").map(String.init)
        )
    }

    mutating func setExpectedProgramNames(_ names: [String]) {
        expectedPrograms = Self.normalizedExpectedProgramNames(names).joined(separator: ", ")
    }

    static func normalizedExpectedProgramNames(_ names: [String]) -> [String] {
        var normalized: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !normalized.contains(where: {
                      $0.caseInsensitiveCompare(trimmed) == .orderedSame
                  }) else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }
}

enum DirectoryGuardRulePersistence {
    static func load(
        data: Data,
        legacyPath: String,
        legacyExpectedPrograms: String,
        legacyOperationRaw: String
    ) -> [DirectoryGuardRule] {
        if !data.isEmpty,
           let decoded = try? JSONDecoder().decode([DirectoryGuardRule].self, from: data) {
            return decoded
        }
        guard !legacyPath.isEmpty else { return [] }
        return [DirectoryGuardRule(
            path: legacyPath,
            operation: DirectoryGuardOperation(rawValue: legacyOperationRaw) ?? .readWrite,
            expectedPrograms: legacyExpectedPrograms
        )]
    }

    static func encode(_ rules: [DirectoryGuardRule]) -> Data {
        (try? JSONEncoder().encode(rules)) ?? Data()
    }
}

struct DirectoryGuardEventMatch: Identifiable, Equatable {
    let event: VolumeAccessTraceEventSummary
    let rule: DirectoryGuardRule

    var id: String { event.id }
}

struct DirectoryGuardProgramActivity: Identifiable, Equatable {
    let id: String
    let rule: DirectoryGuardRule
    let process: VolumeAccessTraceProcessReference
    let eventMatches: [DirectoryGuardEventMatch]
    let readEventCount: Int
    let writeEventCount: Int
    let readBytes: UInt64
    let writeBytes: UInt64
    let readBytesAreComplete: Bool
    let writeBytesAreComplete: Bool
    let unexpectedEventCount: Int

    var eventCount: Int { readEventCount + writeEventCount }
    var isUnexpected: Bool { unexpectedEventCount > 0 }

    var requestedBytes: UInt64 {
        Self.saturatedAdd(readBytes, writeBytes)
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? UInt64.max : result.partialValue
    }
}

struct DirectoryGuardDirectoryActivity: Identifiable, Equatable {
    let rule: DirectoryGuardRule
    let programs: [DirectoryGuardProgramActivity]

    var id: UUID { rule.id }
    var eventCount: Int { programs.reduce(0) { $0 + $1.eventCount } }
    var requestedBytes: UInt64 {
        programs.reduce(0) { partial, program in
            let result = partial.addingReportingOverflow(program.requestedBytes)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }
}

enum DirectoryGuardMatcher {
    static func unexpectedEvents(
        in events: [VolumeAccessTraceEventSummary],
        rules: [DirectoryGuardRule],
        limit: Int? = 40
    ) -> [DirectoryGuardEventMatch] {
        let enabledRules = rules.filter(\.isEnabled)
        guard !enabledRules.isEmpty else { return [] }
        let matchesArray: [DirectoryGuardEventMatch] = events.reversed().compactMap { event in
            guard let rule = enabledRules
                .filter({ contains(event.path, in: $0.path) })
                .max(by: { canonicalPath($0.path).count < canonicalPath($1.path).count }),
                  matches(event.category, operation: rule.operation),
                  !rule.expectedProgramNames.contains(where: {
                    $0.caseInsensitiveCompare(event.process.displayName) == .orderedSame
                  }) else { return nil }
            return DirectoryGuardEventMatch(event: event, rule: rule)
        }
        guard let limit else { return matchesArray }
        return matchesArray.prefix(max(0, limit)).map { $0 }
    }

    static func unexpectedProgramActivities(
        in events: [VolumeAccessTraceEventSummary],
        rules: [DirectoryGuardRule]
    ) -> [DirectoryGuardDirectoryActivity] {
        programActivities(in: events, rules: rules)
    }

    static func programActivities(
        in events: [VolumeAccessTraceEventSummary],
        rules: [DirectoryGuardRule]
    ) -> [DirectoryGuardDirectoryActivity] {
        let matchedEvents: [DirectoryGuardEventMatch] = events.reversed().compactMap { event in
            guard let rule = matchingRule(for: event, rules: rules),
                  matches(event.category, operation: rule.operation) else { return nil }
            return DirectoryGuardEventMatch(event: event, rule: rule)
        }
        let matchesByProgram = Dictionary(grouping: matchedEvents) { match in
            "\(match.rule.id.uuidString)|\(match.event.process.displayName.lowercased())"
        }
        let programs = matchesByProgram.values.compactMap { programMatches -> DirectoryGuardProgramActivity? in
            guard let first = programMatches.first else { return nil }
            let reads = programMatches.filter { $0.event.category == .read }
            let writes = programMatches.filter { $0.event.category == .write }
            let unexpectedCount = programMatches.filter { match in
                !first.rule.expectedProgramNames.contains(where: {
                    $0.caseInsensitiveCompare(match.event.process.displayName) == .orderedSame
                })
            }.count
            return DirectoryGuardProgramActivity(
                id: "\(first.rule.id.uuidString)|\(first.event.process.displayName.lowercased())",
                rule: first.rule,
                process: first.event.process,
                eventMatches: programMatches.sorted { $0.event.timestamp > $1.event.timestamp },
                readEventCount: reads.count,
                writeEventCount: writes.count,
                readBytes: saturatedByteTotal(reads),
                writeBytes: saturatedByteTotal(writes),
                readBytesAreComplete: reads.allSatisfy { $0.event.requestedBytes != nil },
                writeBytesAreComplete: writes.allSatisfy { $0.event.requestedBytes != nil },
                unexpectedEventCount: unexpectedCount
            )
        }
        let programsByRule = Dictionary(grouping: programs, by: { $0.rule.id })
        return programsByRule.values.compactMap { rulePrograms in
            guard let rule = rulePrograms.first?.rule else { return nil }
            return DirectoryGuardDirectoryActivity(
                rule: rule,
                programs: rulePrograms.sorted(by: programSort)
            )
        }.sorted { lhs, rhs in
            if lhs.requestedBytes != rhs.requestedBytes {
                return lhs.requestedBytes > rhs.requestedBytes
            }
            if lhs.eventCount != rhs.eventCount { return lhs.eventCount > rhs.eventCount }
            return lhs.rule.path.localizedStandardCompare(rhs.rule.path) == .orderedAscending
        }
    }

    private static func matchingRule(
        for event: VolumeAccessTraceEventSummary,
        rules: [DirectoryGuardRule]
    ) -> DirectoryGuardRule? {
        rules.filter { $0.isEnabled && contains(event.path, in: $0.path) }
            .max(by: { canonicalPath($0.path).count < canonicalPath($1.path).count })
    }

    private static func programSort(
        _ lhs: DirectoryGuardProgramActivity,
        _ rhs: DirectoryGuardProgramActivity
    ) -> Bool {
        if lhs.requestedBytes != rhs.requestedBytes {
            return lhs.requestedBytes > rhs.requestedBytes
        }
        if lhs.eventCount != rhs.eventCount { return lhs.eventCount > rhs.eventCount }
        return lhs.process.displayName.localizedStandardCompare(rhs.process.displayName)
            == .orderedAscending
    }

    private static func saturatedByteTotal(_ matches: [DirectoryGuardEventMatch]) -> UInt64 {
        matches.reduce(0) { partial, match in
            guard let bytes = match.event.requestedBytes else { return partial }
            let result = partial.addingReportingOverflow(bytes)
            return result.overflow ? UInt64.max : result.partialValue
        }
    }

    private static func matches(
        _ category: VolumeAccessTraceOperationCategory,
        operation: DirectoryGuardOperation
    ) -> Bool {
        switch operation {
        case .readWrite: category == .read || category == .write
        case .read: category == .read
        case .write: category == .write
        }
    }

    private static func contains(_ candidate: String, in root: String) -> Bool {
        let candidate = canonicalPath(candidate)
        let root = canonicalPath(root)
        return candidate == root || candidate.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func canonicalPath(_ path: String) -> String {
        VolumeAccessTraceTarget.canonicalPath(path)
    }
}

enum DirectoryTracePresentationState: Equatable {
    case waitingForActivity
    case showingActivity
    case noActivity

    static let initialWaitWindow: TimeInterval = 8

    static func resolve(
        isCollecting: Bool,
        firstEventAt: Date?,
        elapsed: TimeInterval,
        waitWindow: TimeInterval = initialWaitWindow
    ) -> Self {
        if firstEventAt != nil {
            return .showingActivity
        }
        guard isCollecting else { return .noActivity }
        return elapsed < max(0, waitWindow) ? .waitingForActivity : .noActivity
    }
}

enum DirectoryDetailPresentation: Equatable {
    case sheet
    case overlay
    case split
}

enum DirectoryWorkspaceLayout {
    static let maximumRankedDirectories = 10
    static let detailWidth: CGFloat = 360
    static let splitDetailMinimumWidth: CGFloat = 1_140
    static let overlayDetailMinimumWidth: CGFloat = 760
    static let splitDividerWidth: CGFloat = 1
    static let wideTableMinimumWidth: CGFloat = 700

    static func detailPresentation(for availableWidth: CGFloat) -> DirectoryDetailPresentation {
        if availableWidth >= splitDetailMinimumWidth { return .split }
        if availableWidth >= overlayDetailMinimumWidth { return .overlay }
        return .sheet
    }

    static func primaryContentWidth(for availableWidth: CGFloat) -> CGFloat {
        guard detailPresentation(for: availableWidth) == .split else {
            return max(0, availableWidth)
        }
        return max(0, availableWidth - detailWidth - splitDividerWidth)
    }

    static func usesCompactTable(for availableWidth: CGFloat) -> Bool {
        availableWidth < wideTableMinimumWidth
    }
}

private struct DirectoryDetailSelection: Identifiable, Equatable {
    let path: String

    var id: String { path }
}

private extension FileAccessTraceRunState {
    var isDirectoryTraceCollecting: Bool {
        switch self {
        case .starting, .repairing, .running:
            true
        default:
            false
        }
    }
}

@MainActor
@Observable
final class DirectoryWorkspaceRuntime {
    let volumeTraceStore: VolumeAccessTraceStore
    let targetTraceStore: FileAccessTraceStore
    private(set) var isGuardRunning = false

    init(activityRegistry: TraceActivityRegistry = TraceActivityRegistry()) {
        volumeTraceStore = VolumeAccessTraceStore(activityRegistry: activityRegistry)
        targetTraceStore = FileAccessTraceStore(activityRegistry: activityRegistry)
    }

    func stopAll() {
        isGuardRunning = false
        volumeTraceStore.setAdaptiveSamplingEnabled(false)
        if volumeTraceStore.isRunning { volumeTraceStore.stop() }
        if targetTraceStore.isRunning { targetTraceStore.stop() }
    }

    func setGuardRunning(_ running: Bool) {
        isGuardRunning = running
    }
}

struct DirectoryWorkspaceView: View {
    let store: MonitorStore
    let runtime: DirectoryWorkspaceRuntime

    @State private var volumeTraceStore: VolumeAccessTraceStore
    @State private var targetTraceStore: FileAccessTraceStore
    @State private var selectedTab: DirectoryWorkspaceTab = .top
    @State private var topSort: DirectoryTopSort = .write
    @State private var selectedDirectoryPath: String?
    @State private var compactDirectoryDetail: DirectoryDetailSelection?
    @AppStorage("directoryMonitorPath") private var persistedMonitorPath = ""
    @AppStorage("directoryGuardRulesV2") private var persistedGuardRules = Data()
    @AppStorage("directoryGuardPath") private var legacyGuardPath = ""
    @AppStorage("directoryExpectedPrograms") private var legacyExpectedPrograms = ""
    @AppStorage("directoryGuardOperation") private var legacyGuardOperationRaw = DirectoryGuardOperation.readWrite.rawValue
    @State private var guardRules: [DirectoryGuardRule] = []
    @State private var didLoadGuardRules = false
    @State private var guardRuleDraft: DirectoryGuardRule?
    @State private var pendingGuardRuleDeletion: DirectoryGuardRule?
    @State private var monitorPathCopied = false
    @State private var monitorPathCopyResetTask: Task<Void, Never>?
    @State private var monitorPathChangeTask: Task<Void, Never>?
    @State private var showingTargetTrace = false
    @State private var targetTraceTask: Task<Void, Never>?
    @State private var guardTraceConfigurationTask: Task<Void, Never>?

    init(store: MonitorStore, runtime: DirectoryWorkspaceRuntime) {
        self.store = store
        self.runtime = runtime
        _volumeTraceStore = State(initialValue: runtime.volumeTraceStore)
        _targetTraceStore = State(initialValue: runtime.targetTraceStore)
    }

    var body: some View {
        Group {
            if showingTargetTrace {
                FileAccessTraceView(
                    store: targetTraceStore,
                    onBack: {
                        targetTraceTask?.cancel()
                        targetTraceStore.endEphemeralSession()
                        showingTargetTrace = false
                    }
                )
            } else {
                workspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { InstrumentCanvas() }
        .task { await prepareWorkspace() }
        .onChange(of: processSessionIDs, initial: true) { _, _ in
            let sessions = store.processes.flatMap(\.sessions)
            volumeTraceStore.setProcessSessions(sessions)
            targetTraceStore.setProcessSessions(sessions)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            volumeTraceStore.refreshPermissionStatus()
            targetTraceStore.refreshPermissionStatus()
        }
        .onDisappear {
            monitorPathCopyResetTask?.cancel()
            monitorPathChangeTask?.cancel()
            targetTraceTask?.cancel()
            if targetTraceStore.isRunning { targetTraceStore.stop() }
            if !guardEnabled && volumeTraceStore.isRunning { volumeTraceStore.stop() }
        }
        .sheet(item: $guardRuleDraft) { rule in
            DirectoryGuardRuleEditorView(
                rule: rule,
                reservedPaths: Set(guardRules.filter { $0.id != rule.id }.map(\.path)),
                onSave: saveGuardRule
            )
        }
        .confirmationDialog(
            L10n.text("删除守护目录？"),
            isPresented: Binding(
                get: { pendingGuardRuleDeletion != nil },
                set: { if !$0 { pendingGuardRuleDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingGuardRuleDeletion
        ) { rule in
            Button(L10n.text("删除"), role: .destructive) {
                deleteGuardRule(rule)
            }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { rule in
            Text(L10n.format("将停止守护此目录：%@", rule.path))
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            InstrumentPageHeader(L10n.text("目录")) {
                GlassSegmentedControl(
                    L10n.text("目录工作区"),
                    selection: $selectedTab
                ) {
                    ForEach(DirectoryWorkspaceTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .frame(width: 244)
            }
            Divider()

            if selectedTab == .top {
                topContent
            } else {
                guardContent
            }
        }
    }

    private var topContent: some View {
        GeometryReader { geometry in
            topPresentation(availableWidth: geometry.size.width)
                .onChange(of: geometry.size.width) { oldWidth, newWidth in
                    migrateDetailToSheetIfNeeded(from: oldWidth, to: newWidth)
                }
        }
        .sheet(item: $compactDirectoryDetail, onDismiss: dismissDirectoryDetail) { selection in
            directoryDetailPane(path: selection.path)
                .frame(minWidth: 560, minHeight: 560)
        }
        .animation(.easeOut(duration: 0.18), value: selectedDirectoryPath)
    }

    @ViewBuilder
    private func topPresentation(availableWidth: CGFloat) -> some View {
        if let selectedDirectoryPath {
            switch DirectoryWorkspaceLayout.detailPresentation(for: availableWidth) {
            case .split:
                HStack(spacing: 0) {
                    topResults(
                        availableWidth: DirectoryWorkspaceLayout.primaryContentWidth(
                            for: availableWidth
                        )
                    )
                    Divider()
                    directoryDetailPane(path: selectedDirectoryPath)
                        .frame(width: DirectoryWorkspaceLayout.detailWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            case .overlay:
                topResults(availableWidth: availableWidth)
                    .overlay(alignment: .trailing) {
                        directoryDetailPane(path: selectedDirectoryPath)
                            .frame(width: DirectoryWorkspaceLayout.detailWidth)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Color(nsColor: .separatorColor))
                                    .frame(width: 1)
                            }
                            .visualEffectShadow(
                                color: .black.opacity(0.16),
                                radius: 14,
                                x: -4,
                                y: 0
                            )
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
            case .sheet:
                topResults(availableWidth: availableWidth)
            }
        } else {
            topResults(availableWidth: availableWidth)
        }
    }

    private func topResults(availableWidth: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InstrumentDesign.Spacing.section) {
                SectionHeading(
                    "目录读写排行",
                    subtitle: "每条请求只计入文件所在目录，父目录不重复累计。"
                ) {
                    traceStateBadge
                }

                topControls
                if needsDiagnosticStatusBand { diagnosticStatusBand }
                DirectoryDirectoryTableView(
                    store: volumeTraceStore,
                    sort: topSort,
                    scopePath: monitorPath,
                    selectedPath: selectedDirectoryPath,
                    usesCompactLayout: DirectoryWorkspaceLayout.usesCompactTable(
                        for: availableWidth - InstrumentDesign.Spacing.page * 2
                    ),
                    onSelect: { presentDirectoryDetail($0, availableWidth: availableWidth) },
                    onGuard: beginGuard,
                    onTrace: beginProcessTrace
                )
                if topTracePresentation != .waitingForActivity {
                    DirectoryTopMetricsView(store: volumeTraceStore)
                    DirectoryRateReconciliationView(
                        traceStore: volumeTraceStore,
                        monitorStore: store
                    )
                    DirectoryAnalyticsView(store: volumeTraceStore, sort: topSort)
                    DirectoryCoverageNoteView(coverage: volumeTraceStore.coverage)
                }
            }
            .padding(.horizontal, InstrumentDesign.Spacing.page)
            .padding(.top, InstrumentDesign.Spacing.related)
            .padding(.bottom, InstrumentDesign.Spacing.page)
        }
        .scrollIndicators(.automatic)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func directoryDetailPane(path: String) -> some View {
        ScrollView {
            DirectorySelectionDetailView(
                store: volumeTraceStore,
                path: path,
                onGuard: beginGuard,
                onTrace: beginProcessTrace,
                onDismiss: dismissDirectoryDetail
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InstrumentDesign.Palette.canvasRaised)
        .onExitCommand(perform: dismissDirectoryDetail)
        .accessibilityIdentifier("directory.detailInspector")
    }

    private func presentDirectoryDetail(_ path: String, availableWidth: CGFloat) {
        selectedDirectoryPath = path
        if DirectoryWorkspaceLayout.detailPresentation(for: availableWidth) == .sheet {
            compactDirectoryDetail = DirectoryDetailSelection(path: path)
        }
    }

    private func migrateDetailToSheetIfNeeded(from oldWidth: CGFloat, to newWidth: CGFloat) {
        guard oldWidth >= DirectoryWorkspaceLayout.overlayDetailMinimumWidth,
              newWidth < DirectoryWorkspaceLayout.overlayDetailMinimumWidth,
              compactDirectoryDetail == nil,
              let selectedDirectoryPath else { return }
        compactDirectoryDetail = DirectoryDetailSelection(path: selectedDirectoryPath)
    }

    private func dismissDirectoryDetail() {
        compactDirectoryDetail = nil
        selectedDirectoryPath = nil
    }

    private var topControls: some View {
        GlassSurface(padding: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: InstrumentDesign.Spacing.related) {
                    directorySelector
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)
                    Divider().frame(height: 34)
                    sortSelector
                        .frame(width: 204)
                    Spacer(minLength: InstrumentDesign.Spacing.related)
                    diagnosticAction
                }

                VStack(alignment: .leading, spacing: InstrumentDesign.Spacing.related) {
                    HStack(spacing: InstrumentDesign.Spacing.related) {
                        directorySelector
                            .frame(maxWidth: .infinity, alignment: .leading)
                        diagnosticAction
                    }
                    sortSelector
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var directorySelector: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(Color.blue)
                .frame(width: 3, height: 38)
                .accessibilityHidden(true)

            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.blue)
                .frame(width: 26, height: 26)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text("监控目录"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text(monitorPath)
                        .font(.callout.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                        .help(monitorPath)

                    Divider()
                        .frame(height: 15)
                        .padding(.horizontal, 7)
                        .accessibilityHidden(true)

                    monitorPathActions

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var monitorPathActions: some View {
        HStack(spacing: 2) {
            Button(action: copyMonitorPath) {
                Image(systemName: monitorPathCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(AppIconButtonStyle(
                size: 28,
                isFramed: false,
                tint: monitorPathCopied
                    ? InstrumentDesign.ColorRole.healthy
                    : Color.primary.opacity(0.64)
            ))
            .help(L10n.text("复制路径"))
            .accessibilityLabel(L10n.text("复制路径"))

            Button(action: chooseMonitorDirectory) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false, tint: .blue))
            .help(L10n.text("编辑监控目录"))
            .accessibilityLabel(L10n.text("编辑监控目录"))
        }
        .fixedSize()
    }

    private var sortSelector: some View {
        GlassSegmentedControl(
            L10n.text("排行排序"),
            selection: $topSort
        ) {
            ForEach(DirectoryTopSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .accessibilityLabel(L10n.text("排行排序"))
    }

    private var diagnosticAction: some View {
        Button(action: performDiagnosticPrimaryAction) {
            HStack(spacing: 9) {
                Image(systemName: diagnosticActionSymbol)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(diagnosticActionTitle)
                        .font(.caption.weight(.bold))
                    Text(traceStateTitle)
                        .font(.caption2)
                        .opacity(0.78)
                        .lineLimit(1)
                }

                if diagnosticActionShowsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(width: 16)
                }
            }
            .frame(minWidth: 138, alignment: .leading)
        }
        .buttonStyle(DirectoryDiagnosticButtonStyle(isDestructive: diagnosticActionIsDestructive))
        .disabled(monitoredVolume == nil || diagnosticActionIsDisabled)
        .accessibilityIdentifier("directory.startDiagnosis")
    }

    private var traceStateBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(traceStateColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(traceStateTitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(traceStateColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(traceStateColor.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var diagnosticStatusBand: some View {
        HStack(spacing: 12) {
            Image(systemName: diagnosticStatusSymbol)
                .font(.title3)
                .foregroundStyle(diagnosticStatusColor)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(diagnosticStatusTitle)
                    .font(.headline)
                Text(diagnosticStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(padding: 0)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(diagnosticStatusColor)
                .frame(width: 3)
        }
    }

    private var guardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: InstrumentDesign.Spacing.section) {
                guardControlPanel
                guardDirectoriesPanel
                DirectoryGuardActivityView(
                    store: volumeTraceStore,
                    guardEnabled: guardEnabled,
                    rules: guardRules,
                    onAllowProgram: allowGuardProgram,
                    onTrace: beginProcessTrace
                )
                if guardEnabled || !volumeTraceStore.events.isEmpty {
                    DirectoryCoverageNoteView(coverage: volumeTraceStore.coverage)
                }
            }
            .padding(.horizontal, InstrumentDesign.Spacing.page)
            .padding(.top, InstrumentDesign.Spacing.related)
            .padding(.bottom, InstrumentDesign.Spacing.page)
        }
        .scrollIndicators(.automatic)
    }

    private var guardControlPanel: some View {
        GlassSurface(padding: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    guardControlStatus
                    Divider().frame(height: 34)
                    guardControlMetrics
                    Spacer(minLength: 12)
                    guardPrimaryAction
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        guardControlStatus
                        Spacer(minLength: 8)
                        guardPrimaryAction
                    }
                    guardControlMetrics
                }
            }
            .padding(16)
        }
    }

    private var guardDirectoriesPanel: some View {
        GlassSurface(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text("守护目录"))
                            .font(.headline)
                        Text(L10n.format("%d 个目录", guardRules.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button(action: chooseNewGuardDirectory) {
                        Label(L10n.text("添加目录"), systemImage: "plus")
                    }
                    .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                    .accessibilityIdentifier("directory.guard.addRule")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider()
                if guardRules.isEmpty {
                    guardRulesEmptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(guardRules) { rule in
                            DirectoryGuardRuleRow(
                                rule: rule,
                                onToggle: { setGuardRule(rule.id, enabled: $0) },
                                onEdit: { guardRuleDraft = rule },
                                onDelete: { pendingGuardRuleDeletion = rule }
                            )
                            if rule.id != guardRules.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                }
            }
        }
    }

    private var guardControlStatus: some View {
        HStack(spacing: 12) {
            Image(systemName: guardControlSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(guardControlColor)
                .frame(width: 34, height: 34)
                .background(
                    guardControlColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(guardControlTitle))
                    .font(.headline)
                Text(L10n.format("已启用 %d 个目录", enabledGuardRules.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var guardPrimaryAction: some View {
        Button(action: performGuardPrimaryAction) {
            Label(
                L10n.text(guardPrimaryActionTitle),
                systemImage: guardPrimaryActionSymbol
            )
        }
        .buttonStyle(AppActionButtonStyle(
            kind: guardPrimaryActionIsDestructive ? .destructive : .primary,
            size: .compact
        ))
        .disabled(!guardEnabled && enabledGuardRules.isEmpty)
        .accessibilityIdentifier("directory.guard.primaryAction")
    }

    private var guardPrimaryActionTitle: String {
        if guardTraceNeedsApproval { return "打开登录项设置" }
        if guardTraceNeedsRepair { return "修复并重试" }
        return guardEnabled ? "停止守护" : "启动守护"
    }

    private var guardPrimaryActionSymbol: String {
        if guardTraceNeedsApproval { return "gearshape" }
        if guardTraceNeedsRepair { return "arrow.clockwise" }
        return guardEnabled ? "stop.fill" : "play.fill"
    }

    private var guardPrimaryActionIsDestructive: Bool {
        guardEnabled && !guardTraceNeedsApproval && !guardTraceNeedsRepair
    }

    private var guardTraceNeedsApproval: Bool {
        switch volumeTraceStore.state {
        case .permissionRequired, .waitingForApproval: true
        default: false
        }
    }

    private var guardTraceNeedsRepair: Bool {
        switch volumeTraceStore.state {
        case .repairAvailable, .failed, .unsupportedFormat: true
        default: false
        }
    }

    private func performGuardPrimaryAction() {
        if guardTraceNeedsApproval {
            if case .permissionRequired = volumeTraceStore.state {
                volumeTraceStore.requestPermission()
            } else {
                volumeTraceStore.openApprovalSettings()
            }
            return
        }
        if guardTraceNeedsRepair {
            volumeTraceStore.repairAndRetry()
            return
        }
        toggleGuard()
    }

    private var guardControlMetrics: some View {
        HStack(spacing: 18) {
            guardSummaryMetric(
                title: "采集节奏",
                value: guardEnabled ? L10n.text("10 秒采集 · 50 秒休眠") : L10n.text("等待启动"),
                symbol: "gauge.with.dots.needle.33percent",
                color: guardEnabled ? InstrumentDesign.ColorRole.healthy : .secondary
            )
            guardSummaryMetric(
                title: "负载保护",
                value: volumeTraceStore.samplingStride > 1
                    ? L10n.format("采样 ×%d", volumeTraceStore.samplingStride)
                    : L10n.text("自动采样"),
                symbol: "dial.medium",
                color: volumeTraceStore.samplingStride > 1 ? .orange : .secondary
            )
        }
    }

    private var guardControlTitle: String {
        if !guardEnabled { return "守护已停止" }
        if guardTraceNeedsApproval { return "需要授权" }
        if guardTraceNeedsRepair { return "追踪组件未能启动" }
        return volumeTraceStore.state.isDirectoryTraceCollecting
            ? "正在采集目录活动"
            : "低 CPU 等待中"
    }

    private var guardControlSymbol: String {
        if !guardEnabled { return "shield" }
        if guardTraceNeedsApproval || guardTraceNeedsRepair {
            return "exclamationmark.triangle"
        }
        return volumeTraceStore.state.isDirectoryTraceCollecting
            ? "shield.checkered"
            : "moon.zzz.fill"
    }

    private var guardControlColor: Color {
        if !guardEnabled { return .secondary }
        if guardTraceNeedsApproval || guardTraceNeedsRepair { return .orange }
        return volumeTraceStore.state.isDirectoryTraceCollecting
            ? InstrumentDesign.ColorRole.healthy
            : .blue
    }

    private func guardSummaryMetric(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var guardRulesEmptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 25))
                .foregroundStyle(Color.accentColor.opacity(0.78))
            Text(L10n.text("还没有守护目录"))
                .font(.headline)
            Text(L10n.text("添加需要持续观察的目录，再为每个目录配置允许的程序和读写类型。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 168)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    /// Directory tracing is valid for external and network-mounted volumes as
    /// well as the startup volume. `VolumeInfo.isLocal` describes where the
    /// volume lives, not whether fs_usage can report paths on it, so using it
    /// as a filter silently makes `/Volumes/...` targets impossible to start.
    private var availableVolumes: [VolumeInfo] {
        store.volumes
    }

    private var topTracePresentation: DirectoryTracePresentationState {
        .resolve(
            isCollecting: volumeTraceStore.state.isDirectoryTraceCollecting,
            firstEventAt: volumeTraceStore.firstEventAt,
            elapsed: volumeTraceStore.elapsed
        )
    }

    private var processSessionIDs: [String] {
        store.processes.flatMap(\.sessions).map { "\($0.pid):\($0.startAbstime)" }
    }

    private var guardEnabled: Bool {
        runtime.isGuardRunning
    }

    private var enabledGuardRules: [DirectoryGuardRule] {
        guardRules.filter(\.isEnabled)
    }

    private var monitorPath: String {
        if !persistedMonitorPath.isEmpty { return persistedMonitorPath }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private var monitoredVolume: VolumeInfo? {
        VolumePathResolver.bestMatch(for: monitorPath, in: availableVolumes)
    }

    private var traceStateTitle: String {
        switch volumeTraceStore.state {
        case .running: L10n.text("正在诊断")
        case .starting: L10n.text("正在启动")
        case .stopping, .stopUnconfirmed: L10n.text("正在停止")
        case .permissionRequired, .waitingForApproval: L10n.text("需要授权")
        case .repairing: L10n.text("正在更新")
        case .stopped: L10n.text("已停止")
        case .repairAvailable, .installationRequired, .failed, .unsupportedFormat:
            L10n.text("需要处理")
        default: L10n.text("等待开始")
        }
    }

    private var traceStateColor: Color {
        switch volumeTraceStore.state {
        case .running: InstrumentDesign.ColorRole.healthy
        case .starting, .repairing: .blue
        case .permissionRequired, .waitingForApproval, .repairAvailable,
                .installationRequired, .failed, .unsupportedFormat,
                .stopUnconfirmed:
            .orange
        default: .secondary
        }
    }

    private var diagnosticActionTitle: String {
        switch volumeTraceStore.state {
        case .running, .starting, .repairing:
            L10n.text("停止诊断")
        case .permissionRequired:
            L10n.text("启用追踪")
        case .waitingForApproval:
            L10n.text("打开登录项设置")
        case .repairAvailable:
            L10n.text("修复并重试")
        case .installationRequired:
            L10n.text("打开安装窗口")
        case .failed, .unsupportedFormat:
            L10n.text("重试")
        default:
            L10n.text("开始诊断")
        }
    }

    private var diagnosticActionSymbol: String {
        switch volumeTraceStore.state {
        case .running, .starting, .repairing: "stop.fill"
        case .permissionRequired: "lock.open"
        case .waitingForApproval: "gearshape"
        case .repairAvailable: "wrench.and.screwdriver"
        case .installationRequired: "folder.badge.plus"
        case .failed, .unsupportedFormat: "arrow.clockwise"
        default: "waveform.path.ecg"
        }
    }

    private var diagnosticActionIsDestructive: Bool {
        switch volumeTraceStore.state {
        case .running, .starting, .repairing: true
        default: false
        }
    }

    private var diagnosticActionShowsProgress: Bool {
        switch volumeTraceStore.state {
        case .starting, .repairing, .stopping, .stopUnconfirmed: true
        default: false
        }
    }

    private var diagnosticActionIsDisabled: Bool {
        switch volumeTraceStore.state {
        case .stopping, .stopUnconfirmed: true
        default: false
        }
    }

    private var needsDiagnosticStatusBand: Bool {
        switch volumeTraceStore.state {
        case .permissionRequired, .waitingForApproval, .repairing,
                .repairAvailable, .installationRequired, .failed,
                .unsupportedFormat, .stopping, .stopUnconfirmed:
            true
        default:
            false
        }
    }

    private var diagnosticStatusTitle: String {
        switch volumeTraceStore.state {
        case .permissionRequired: L10n.text("需要启用文件访问追踪")
        case .waitingForApproval: L10n.text("等待你在系统设置中批准")
        case .repairing: L10n.text("正在更新追踪组件")
        case .repairAvailable: L10n.text("追踪组件未能启动")
        case .stopping: L10n.text("正在停止追踪")
        case .stopUnconfirmed: L10n.text("正在确认追踪已结束")
        case .installationRequired: L10n.text("需要先安装到应用程序文件夹")
        case .unsupportedFormat: L10n.text("当前 macOS 输出格式暂不受支持")
        case .failed(let message): message
        default: ""
        }
    }

    private var diagnosticStatusDetail: String {
        switch volumeTraceStore.state {
        case .permissionRequired:
            L10n.text("点击启用后，macOS 会请求一次管理员确认。FindDiskKiller 不会在后台自行申请。")
        case .waitingForApproval:
            L10n.text("在“登录项与扩展”中允许 FindDiskKiller 后返回这里，追踪会自动开始。")
        case .repairing:
            L10n.text("正在替换旧版追踪组件，完成后会自动继续。")
        case .repairAvailable:
            L10n.text("组件已启用但未能启动。请直接修复，无需重复切换系统设置；已有结果会保留。")
        case .stopping:
            L10n.text("仍可检查更新；如需安装，将在追踪完全停止后自动继续。")
        case .stopUnconfirmed:
            L10n.text("仍可检查更新；确认后台追踪结束前不会开始安装。")
        case .installationRequired(let isDiskImage):
            isDiskImage
                ? L10n.text("请在安装窗口中将 FindDiskKiller 拖入“应用程序”，然后重新打开。")
                : L10n.text("请将 FindDiskKiller 移入“应用程序”文件夹，然后重新打开。")
        case .unsupportedFormat:
            L10n.text("为了避免显示看似精确但含义错误的数字，本次结果已停止统计。")
        case .failed:
            L10n.text("请检查追踪组件状态后重试；已有结果仍保留在当前会话中。")
        default:
            ""
        }
    }

    private var diagnosticStatusSymbol: String {
        switch volumeTraceStore.state {
        case .permissionRequired, .waitingForApproval: "lock.shield"
        case .repairing, .stopping, .stopUnconfirmed: "arrow.triangle.2.circlepath"
        case .repairAvailable: "wrench.and.screwdriver"
        case .installationRequired: "folder.badge.plus"
        case .unsupportedFormat: "doc.badge.ellipsis"
        default: "exclamationmark.triangle"
        }
    }

    private var diagnosticStatusColor: Color {
        switch volumeTraceStore.state {
        case .permissionRequired, .waitingForApproval, .repairing, .stopping: .blue
        default: .orange
        }
    }

    private var samplingTitle: String {
        volumeTraceStore.samplingStride > 1
            ? L10n.format("采样 ×%d", volumeTraceStore.samplingStride)
            : L10n.text("完整捕获")
    }

    private var samplingColor: Color {
        volumeTraceStore.samplingStride > 1 ? .orange : InstrumentDesign.ColorRole.healthy
    }

    private func prepareWorkspace() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        if !didLoadGuardRules {
            guardRules = DirectoryGuardRulePersistence.load(
                data: persistedGuardRules,
                legacyPath: legacyGuardPath,
                legacyExpectedPrograms: legacyExpectedPrograms,
                legacyOperationRaw: legacyGuardOperationRaw
            )
            didLoadGuardRules = true
            persistGuardRules()
        }
        if persistedMonitorPath.isEmpty {
            persistedMonitorPath = FileManager.default.homeDirectoryForCurrentUser.path
        }
        if let volume = monitoredVolume,
           volumeTraceStore.selection?.directoryPath != monitorPath {
            volumeTraceStore.select(volume, directoryPath: monitorPath)
        }
    }

    private func toggleDiagnostic() {
        if guardEnabled {
            let wasCapturingGuard = volumeTraceStore.isRunning
            stopGuard()
            if wasCapturingGuard { return }
        }
        if volumeTraceStore.isRunning {
            volumeTraceStore.stop()
            return
        }
        guard let volume = monitoredVolume else { return }
        if volumeTraceStore.selection?.directoryPath != monitorPath {
            volumeTraceStore.select(volume, directoryPath: monitorPath)
        }
        // Keep a normal stream lossless; switch to a bounded stride only when
        // the event rate crosses the adaptive sampling thresholds.
        volumeTraceStore.setAdaptiveSamplingEnabled(true)
        volumeTraceStore.start()
    }

    private func performDiagnosticPrimaryAction() {
        switch volumeTraceStore.state {
        case .permissionRequired:
            volumeTraceStore.requestPermission()
        case .waitingForApproval:
            volumeTraceStore.openApprovalSettings()
        case .repairAvailable:
            volumeTraceStore.repairAndRetry()
        case .installationRequired:
            volumeTraceStore.openInstallationLocation()
        default:
            toggleDiagnostic()
        }
    }

    private func toggleGuard() {
        if guardEnabled {
            stopGuard()
            return
        }
        guard !enabledGuardRules.isEmpty else { return }
        runtime.setGuardRunning(true)
        restartGuardTrace()
    }

    private func beginGuard(for path: String) {
        selectedTab = .guardRule
        let canonicalPath = VolumeAccessTraceTarget.canonicalPath(path)
        if let index = guardRules.firstIndex(where: { $0.path == canonicalPath }) {
            guardRules[index].isEnabled = true
        } else {
            guardRules.append(DirectoryGuardRule(path: canonicalPath))
        }
        persistGuardRules()
        if guardEnabled {
            restartGuardTrace()
        } else {
            toggleGuard()
        }
    }

    private func allowGuardProgram(ruleID: UUID, program: String) {
        let normalized = program.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let index = guardRules.firstIndex(where: { $0.id == ruleID }) else { return }
        let values = guardRules[index].expectedProgramNames
        guard !values.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else { return }
        guardRules[index].expectedPrograms = (values + [normalized]).joined(separator: ", ")
        persistGuardRules()
    }

    private func beginProcessTrace(for path: String) {
        if volumeTraceStore.isRunning { volumeTraceStore.stop() }
        targetTraceTask?.cancel()
        targetTraceTask = Task { @MainActor in
            for _ in 0..<50 {
                if !volumeTraceStore.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            targetTraceStore.setProcessSessions(store.processes.flatMap(\.sessions))
            targetTraceStore.beginTracing(URL(fileURLWithPath: path, isDirectory: true))
            showingTargetTrace = true
        }
    }

    private func chooseNewGuardDirectory() {
        chooseDirectory(title: L10n.text("选择守护目录")) { path in
            let canonicalPath = VolumeAccessTraceTarget.canonicalPath(path)
            guardRuleDraft = guardRules.first(where: { $0.path == canonicalPath })
                ?? DirectoryGuardRule(path: canonicalPath)
        }
    }

    private func saveGuardRule(_ rule: DirectoryGuardRule) {
        let canonicalRule = DirectoryGuardRule(
            id: rule.id,
            path: rule.path,
            operation: rule.operation,
            expectedPrograms: rule.expectedPrograms,
            isEnabled: rule.isEnabled
        )
        let previousRule = guardRules.first(where: { $0.id == canonicalRule.id })
        if let index = guardRules.firstIndex(where: { $0.id == canonicalRule.id }) {
            guardRules[index] = canonicalRule
        } else {
            guardRules.append(canonicalRule)
        }
        persistGuardRules()
        guardRuleDraft = nil

        let targetChanged = previousRule == nil
            || previousRule?.path != canonicalRule.path
            || previousRule?.isEnabled != canonicalRule.isEnabled
        if guardEnabled && targetChanged {
            restartGuardTrace()
        }
    }

    private func setGuardRule(_ id: UUID, enabled: Bool) {
        guard let index = guardRules.firstIndex(where: { $0.id == id }),
              guardRules[index].isEnabled != enabled else { return }
        guardRules[index].isEnabled = enabled
        persistGuardRules()
        if guardEnabled { restartGuardTrace() }
    }

    private func deleteGuardRule(_ rule: DirectoryGuardRule) {
        guardRules.removeAll { $0.id == rule.id }
        pendingGuardRuleDeletion = nil
        persistGuardRules()
        if guardEnabled { restartGuardTrace() }
    }

    private func persistGuardRules() {
        persistedGuardRules = DirectoryGuardRulePersistence.encode(guardRules)
    }

    private func stopGuard() {
        guardTraceConfigurationTask?.cancel()
        guardTraceConfigurationTask = nil
        runtime.setGuardRunning(false)
        volumeTraceStore.setAdaptiveSamplingEnabled(false)
        if volumeTraceStore.isRunning { volumeTraceStore.stop() }
    }

    private func restartGuardTrace() {
        guardTraceConfigurationTask?.cancel()
        let paths = enabledGuardRules.map(\.path)
        guard !paths.isEmpty else {
            stopGuard()
            return
        }

        volumeTraceStore.setAdaptiveSamplingEnabled(false)
        if volumeTraceStore.isRunning { volumeTraceStore.stop() }
        guardTraceConfigurationTask = Task { @MainActor in
            for _ in 0..<100 {
                guard !Task.isCancelled, runtime.isGuardRunning else { return }
                if !volumeTraceStore.isRunning,
                   volumeTraceStore.selectDirectories(
                       paths,
                       availableVolumes: availableVolumes
                   ) {
                    // A mounted volume can arrive a few frames after the
                    // Directory screen. Start as soon as path resolution is
                    // possible instead of leaving a misleading running state.
                    volumeTraceStore.setAdaptiveSamplingEnabled(true)
                    volumeTraceStore.startLowCPUGuard()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, runtime.isGuardRunning else { return }
            // Do not present "running" when a configured path cannot be
            // resolved to any mounted volume. The user can retry after the
            // volume is mounted or choose a different directory.
            runtime.setGuardRunning(false)
        }
    }

    private func chooseMonitorDirectory() {
        chooseDirectory(title: L10n.text("选择监控目录")) { path in
            changeMonitorDirectory(to: path)
        }
    }

    private func changeMonitorDirectory(to path: String) {
        let shouldResumeDiagnosis = volumeTraceStore.isRunning && !guardEnabled
        let targetVolume = volume(for: path)

        persistedMonitorPath = path
        monitorPathChangeTask?.cancel()

        guard shouldResumeDiagnosis else {
            if !volumeTraceStore.isRunning, let targetVolume {
                volumeTraceStore.select(targetVolume, directoryPath: path)
            }
            return
        }

        volumeTraceStore.stop()
        monitorPathChangeTask = Task { @MainActor in
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if !volumeTraceStore.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled,
                  !volumeTraceStore.isRunning,
                  let targetVolume else { return }
            volumeTraceStore.select(targetVolume, directoryPath: path)
            volumeTraceStore.setAdaptiveSamplingEnabled(true)
            volumeTraceStore.start()
        }
    }

    private func copyMonitorPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(monitorPath, forType: .string)
        monitorPathCopied = true
        monitorPathCopyResetTask?.cancel()
        monitorPathCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            monitorPathCopied = false
        }
    }

    private func chooseDirectory(
        title: String,
        onChoose: @escaping @MainActor (String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = L10n.text("选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            Task { @MainActor in onChoose(path) }
        }
    }

    private func volume(for path: String) -> VolumeInfo? {
        VolumePathResolver.bestMatch(for: path, in: availableVolumes)
    }

}

private struct DirectoryTopMetricsView: View {
    let store: VolumeAccessTraceStore

    var body: some View {
        GlassSurface(padding: 12) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 176), spacing: 16)],
                alignment: .leading,
                spacing: 14
            ) {
                metric(
                    title: "累计请求读取",
                    value: store.requestedReadBytes.map(ByteRateFormatter.bytes) ?? L10n.text("尚未开始"),
                    symbol: "arrow.down.to.line",
                    color: InstrumentDesign.ColorRole.diskRead
                )
                metric(
                    title: "累计请求写入",
                    value: store.requestedWriteBytes.map(ByteRateFormatter.bytes) ?? L10n.text("尚未开始"),
                    symbol: "arrow.up.to.line",
                    color: InstrumentDesign.ColorRole.diskWrite
                )
                metric(
                    title: "已发现目录",
                    value: store.directories.isEmpty ? "--" : L10n.number(store.directories.count),
                    symbol: "folder",
                    color: InstrumentDesign.ColorRole.cpu
                )
                metric(
                    title: "捕获策略",
                    value: store.samplingStride > 1
                        ? L10n.format("采样 ×%d", store.samplingStride)
                        : L10n.text("完整捕获"),
                    symbol: store.samplingStride > 1 ? "dial.medium" : "scope",
                    color: store.samplingStride > 1 ? .orange : InstrumentDesign.ColorRole.healthy
                )
            }
        }
    }

    private func metric(title: String, value: String, symbol: String, color: Color) -> some View {
        DirectoryMetric(title: L10n.text(title), value: value, color: color, symbol: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keeps the two write-accounting layers visible together. The trace rate is
/// derived from successful fs_usage request bytes; the device rate comes from
/// the selected volume's physical BSD devices. They intentionally are not
/// combined because caching and APFS writeback make them different measures.
private struct DirectoryRateReconciliationView: View {
    let traceStore: VolumeAccessTraceStore
    let monitorStore: MonitorStore

    var body: some View {
        GlassSurface(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                SectionHeading(
                    L10n.text("请求读写速率"),
                    subtitle: L10n.text("这里统计应用向系统请求的读写量；缓存、APFS 写回、压缩与 CoW 会使它和物理磁盘吞吐不同。")
                )

                HStack(spacing: 12) {
                    liveMetric(
                        title: L10n.text("请求写入"),
                        value: traceStore.currentWriteBytesPerSecond.map(ByteRateFormatter.rate)
                            ?? L10n.text("尚未开始"),
                        symbol: "arrow.up.to.line",
                        color: InstrumentDesign.ColorRole.diskWrite
                    )
                    liveMetric(
                        title: L10n.text("物理设备写入"),
                        value: physicalWriteRate.map(ByteRateFormatter.rate)
                            ?? L10n.text("暂无关联设备"),
                        symbol: "internaldrive",
                        color: InstrumentDesign.ColorRole.cpu
                    )
                }
            }
        }
    }

    private func liveMetric(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 25, height: 25)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var physicalWriteRate: Double? {
        guard let volume = traceStore.selection?.volume else { return nil }
        let physicalNames = Set(volume.physicalDiskBSDNames)
        guard !physicalNames.isEmpty else { return nil }
        let matchingDisks = monitorStore.disks.filter { disk in
            disk.isPhysical && physicalNames.contains(disk.bsdName)
        }
        guard !matchingDisks.isEmpty else { return nil }
        return matchingDisks.reduce(0) { $0 + $1.writeBytesPerSecond }
    }
}

private struct DirectoryAnalyticsView: View {
    let store: VolumeAccessTraceStore
    let sort: DirectoryTopSort

    var body: some View {
        GlassSurface(padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(
                    L10n.text("请求读写速率"),
                    subtitle: L10n.text("最近 5 秒平均值 · 折线")
                ) {
                    DirectoryChartLegend()
                }

                HStack(alignment: .top, spacing: 16) {
                    DirectoryRateTimelineChart(points: store.ratePoints)
                        .frame(minWidth: 300, maxWidth: .infinity)
                    Divider().frame(height: 210)
                    DirectoryCompositionView(store: store)
                    .frame(width: 190)
                }

                if !rankedDirectories.isEmpty {
                    Divider()
                    SectionHeading(
                        L10n.text("目录读写排行"),
                        subtitle: L10n.format("仅本目录 · 按%@排序", sort.title)
                    )
                    DirectoryTopActivityChart(rows: Array(rankedDirectories.prefix(7)))
                }
            }
        }
    }

    private var rankedDirectories: [DirectoryRankedRow] {
        sortedDirectories.prefix(DirectoryWorkspaceLayout.maximumRankedDirectories).enumerated().map {
            DirectoryRankedRow(rank: $0.offset + 1, directory: $0.element)
        }
    }

    private var sortedDirectories: [VolumeAccessTraceDirectorySummary] {
        store.directories.sorted { lhs, rhs in
            switch sort {
            case .write:
                return (lhs.requestedWriteBytes, lhs.requestedReadBytes, lhs.path)
                    > (rhs.requestedWriteBytes, rhs.requestedReadBytes, rhs.path)
            case .read:
                return (lhs.requestedReadBytes, lhs.requestedWriteBytes, lhs.path)
                    > (rhs.requestedReadBytes, rhs.requestedWriteBytes, rhs.path)
            case .events:
                return (lhs.eventCount, lhs.requestedWriteBytes, lhs.path)
                    > (rhs.eventCount, rhs.requestedWriteBytes, rhs.path)
            }
        }
    }
}

private struct DirectoryDirectoryTableView: View {
    let store: VolumeAccessTraceStore
    let sort: DirectoryTopSort
    let scopePath: String
    let selectedPath: String?
    let usesCompactLayout: Bool
    let onSelect: (String) -> Void
    let onGuard: (String) -> Void
    let onTrace: (String) -> Void

    var body: some View {
        GlassSurface(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.text("目录")).font(.headline)
                    Spacer(minLength: 12)
                    Text(L10n.format("仅本目录 · 按%@排序", sort.title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                Divider()
                if rankedDirectories.isEmpty {
                    emptyState
                } else {
                    tableHeader
                    Divider().padding(.leading, 56)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rankedDirectories.enumerated()), id: \.element.id) { index, row in
                            DirectoryRowView(
                                row: row,
                                scopePath: scopePath,
                                isSelected: selectedPath == row.directory.path,
                                usesCompactLayout: usesCompactLayout,
                                maxReadBytes: maxReadBytes,
                                maxWriteBytes: maxWriteBytes,
                                onSelect: onSelect,
                                onGuard: onGuard,
                                onTrace: onTrace
                            )
                            if index + 1 < rankedDirectories.count {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rankedDirectories: [DirectoryRankedRow] {
        sortedDirectories.prefix(DirectoryWorkspaceLayout.maximumRankedDirectories).enumerated().map {
            DirectoryRankedRow(rank: $0.offset + 1, directory: $0.element)
        }
    }

    private var sortedDirectories: [VolumeAccessTraceDirectorySummary] {
        store.directories.sorted { lhs, rhs in
            switch sort {
            case .write:
                return (lhs.requestedWriteBytes, lhs.requestedReadBytes, lhs.path)
                    > (rhs.requestedWriteBytes, rhs.requestedReadBytes, rhs.path)
            case .read:
                return (lhs.requestedReadBytes, lhs.requestedWriteBytes, lhs.path)
                    > (rhs.requestedReadBytes, rhs.requestedWriteBytes, rhs.path)
            case .events:
                return (lhs.eventCount, lhs.requestedWriteBytes, lhs.path)
                    > (rhs.eventCount, rhs.requestedWriteBytes, rhs.path)
            }
        }
    }

    private var maxReadBytes: UInt64 {
        max(rankedDirectories.map(\.directory.requestedReadBytes).max() ?? 1, 1)
    }

    private var maxWriteBytes: UInt64 {
        max(rankedDirectories.map(\.directory.requestedWriteBytes).max() ?? 1, 1)
    }

    private var dataPresentation: DirectoryTracePresentationState {
        .resolve(
            isCollecting: store.state.isDirectoryTraceCollecting,
            firstEventAt: store.firstEventAt,
            elapsed: store.elapsed
        )
    }

    private var tableHeader: some View {
        HStack(spacing: usesCompactLayout ? 10 : 12) {
            Image(systemName: "number")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityLabel(L10n.text("排行排序"))
            Text(L10n.text("目录"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if usesCompactLayout {
                Text(L10n.text("读写"))
                    .frame(width: 96, alignment: .trailing)
                Color.clear.frame(width: 68)
            } else {
                Text(L10n.text("读取")).frame(width: 112, alignment: .trailing)
                Text(L10n.text("写入")).frame(width: 112, alignment: .trailing)
                Text(L10n.text("事件")).frame(width: 64, alignment: .trailing)
                Color.clear.frame(width: 68)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch dataPresentation {
        case .waitingForActivity:
            DirectoryTraceWaitingStateView(path: scopePath)
        case .showingActivity, .noActivity:
            DirectoryTraceNoActivityStateView(
                path: scopePath,
                isCollecting: store.state.isDirectoryTraceCollecting
            )
        }
    }
}

private struct DirectoryTraceWaitingStateView: View {
    let path: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            ProgressView()
                .controlSize(.small)
            Text(L10n.text("正在等待目录活动"))
                .font(.headline)
            Text(L10n.text("实时诊断已启动；首次读写可能需要几秒，检测到事件后会自动填充排行。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
            Label(path, systemImage: "folder")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
        .frame(maxWidth: .infinity, minHeight: 238)
        .padding(20)
        .accessibilityElement(children: .combine)
        .accessibilityValue(L10n.text("正在等待目录活动"))
    }
}

private struct DirectoryTraceNoActivityStateView: View {
    let path: String
        let isCollecting: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 27))
                .foregroundStyle(.secondary.opacity(0.68))
            Text(L10n.text(isCollecting ? "暂未观察到目录活动" : "暂无目录读写"))
                .font(.headline)
            Text(L10n.text(isCollecting
                ? "诊断仍在运行，但目前还没有捕获到此目录及其子目录的读写请求。可以在目标目录中打开或保存一个文件后继续观察。"
                : "开始诊断后，系统观察到的目录请求会显示在这里。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 430)
            Label(path, systemImage: "folder")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path)
        }
        .frame(maxWidth: .infinity, minHeight: 238)
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}

private struct DirectoryRowView: View {
    let row: DirectoryRankedRow
    let scopePath: String
    let isSelected: Bool
    let usesCompactLayout: Bool
    let maxReadBytes: UInt64
    let maxWriteBytes: UInt64
    let onSelect: (String) -> Void
    let onGuard: (String) -> Void
    let onTrace: (String) -> Void

    var body: some View {
        Group {
            if usesCompactLayout {
                compactRow
            } else {
                wideRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.09) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(row.directory.path) }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint(L10n.text("查看详情"))
    }

    private var wideRow: some View {
        HStack(spacing: 12) {
            Text(L10n.number(row.rank))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.rank <= 3 ? Color.accentColor : .secondary)
                .frame(width: 28, alignment: .center)
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(InstrumentDesign.ColorRole.cpu)
                .frame(width: 25, height: 25)
                .background(InstrumentDesign.ColorRole.cpu.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(row.directory.path))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(relativePath(row.directory.path))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            DirectoryUsageColumn(
                title: L10n.text("读取"),
                value: row.directory.requestedReadBytes,
                color: InstrumentDesign.ColorRole.diskRead,
                fraction: Double(row.directory.requestedReadBytes) / Double(maxReadBytes)
            )
            DirectoryUsageColumn(
                title: L10n.text("写入"),
                value: row.directory.requestedWriteBytes,
                color: InstrumentDesign.ColorRole.diskWrite,
                fraction: Double(row.directory.requestedWriteBytes) / Double(maxWriteBytes)
            )
            Text(L10n.number(row.directory.eventCount))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            HStack(spacing: 4) {
                Button { onGuard(row.directory.path) } label: {
                    Image(systemName: "shield.lefthalf.filled")
                }
                .buttonStyle(AppIconButtonStyle(size: 30))
                .help(L10n.text("设置实时守护"))
                .accessibilityLabel(L10n.text("设置实时守护"))
                Button { onTrace(row.directory.path) } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(AppIconButtonStyle(size: 30))
                .help(L10n.text("实时程序追踪"))
                .accessibilityLabel(L10n.text("实时程序追踪"))
            }
            .frame(width: 68)
        }
    }

    private var compactRow: some View {
        HStack(spacing: 10) {
            Text(L10n.number(row.rank))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(row.rank <= 3 ? Color.accentColor : .secondary)
                .frame(width: 28, alignment: .center)
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(InstrumentDesign.ColorRole.cpu)
                .frame(width: 25, height: 25)
                .background(
                    InstrumentDesign.ColorRole.cpu.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(row.directory.path))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(relativePath(row.directory.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "bolt.fill")
                        .accessibilityHidden(true)
                    Text(L10n.number(row.directory.eventCount))
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            DirectoryCompactUsageColumn(
                readBytes: row.directory.requestedReadBytes,
                writeBytes: row.directory.requestedWriteBytes
            )
            rowActions
        }
    }

    private var rowActions: some View {
        HStack(spacing: 4) {
            Button { onGuard(row.directory.path) } label: {
                Image(systemName: "shield.lefthalf.filled")
            }
            .buttonStyle(AppIconButtonStyle(size: 30))
            .help(L10n.text("设置实时守护"))
            .accessibilityLabel(L10n.text("设置实时守护"))
            Button { onTrace(row.directory.path) } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(AppIconButtonStyle(size: 30))
            .help(L10n.text("实时程序追踪"))
            .accessibilityLabel(L10n.text("实时程序追踪"))
        }
        .frame(width: 68)
    }

    private func displayName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func relativePath(_ path: String) -> String {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedScope = URL(fileURLWithPath: scopePath).standardizedFileURL.path
        guard normalizedPath != normalizedScope else { return "." }
        guard normalizedPath.hasPrefix(normalizedScope + "/") else { return normalizedPath }
        return "./" + String(normalizedPath.dropFirst(normalizedScope.count + 1))
    }
}

private struct DirectorySelectionDetailView: View {
    let store: VolumeAccessTraceStore
    let path: String
    let onGuard: (String) -> Void
    let onTrace: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                summaryColumn
                Divider()
                processesColumn
                Divider()
                eventsColumn
            }
            .padding(16)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "folder.fill")
                .foregroundStyle(InstrumentDesign.ColorRole.cpu)
                .frame(width: 28, height: 28)
                .background(InstrumentDesign.ColorRole.cpu.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(AppIconButtonStyle(size: 30))
            .help(L10n.text("在 Finder 中显示"))
            .accessibilityLabel(L10n.text("在 Finder 中显示"))
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(AppIconButtonStyle(size: 30))
                .help(L10n.text("关闭详情"))
                .accessibilityLabel(L10n.text("关闭详情"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("本目录直接活动")).font(.headline)
                Text(L10n.text("每条请求只会在排行中计入一次。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            detailMetric(L10n.text("读取"), ByteRateFormatter.bytes(directory?.requestedReadBytes ?? 0), InstrumentDesign.ColorRole.diskRead)
            detailMetric(L10n.text("写入"), ByteRateFormatter.bytes(directory?.requestedWriteBytes ?? 0), InstrumentDesign.ColorRole.diskWrite)
            detailMetric(L10n.text("事件"), L10n.number(directory?.eventCount ?? 0), .secondary)
            Divider()
            Text(L10n.text("含子目录合计")).font(.callout.weight(.semibold))
            detailMetric(
                L10n.text("读取"),
                ByteRateFormatter.bytes(directory?.requestedReadBytesIncludingDescendants ?? 0),
                InstrumentDesign.ColorRole.diskRead
            )
            detailMetric(
                L10n.text("写入"),
                ByteRateFormatter.bytes(directory?.requestedWriteBytesIncludingDescendants ?? 0),
                InstrumentDesign.ColorRole.diskWrite
            )
            detailMetric(
                L10n.text("事件"),
                L10n.number(directory?.eventCountIncludingDescendants ?? 0),
                .secondary
            )
            if let lastEvent = directory?.lastEventAtIncludingDescendants {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("最后活动")).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.relativeDate(lastEvent)).font(.caption.weight(.medium))
                }
            }
            HStack(spacing: 8) {
                Button { onTrace(path) } label: {
                    Label(L10n.text("实时程序追踪"), systemImage: "scope")
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                Button { onGuard(path) } label: {
                    Label(L10n.text("设置实时守护"), systemImage: "shield.lefthalf.filled")
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processesColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("访问应用（含子目录）")).font(.headline)
            if processes.isEmpty {
                Text(L10n.text("本次观察未发现"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            } else {
                ForEach(processes) { process in
                    HStack(spacing: 8) {
                        Circle().fill(process.isWrite ? InstrumentDesign.ColorRole.diskWrite : InstrumentDesign.ColorRole.diskRead).frame(width: 6, height: 6)
                        Text(process.name).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.number(process.eventCount)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eventsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("最近事件（含子目录）")).font(.headline)
            if recentEvents.isEmpty {
                Text(L10n.text("本次观察未发现"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
            } else {
                ForEach(recentEvents) { event in
                    HStack(spacing: 7) {
                        Text(event.category == .write ? L10n.text("写入") : L10n.text("读取"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(event.category == .write ? InstrumentDesign.ColorRole.diskWrite : InstrumentDesign.ColorRole.diskRead)
                        Text(event.process.displayName).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.relativeDate(event.timestamp, abbreviated: true)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }

    private var directory: VolumeAccessTraceDirectorySummary? {
        store.directories.first { $0.path == path }
    }

    private var relevantEvents: [VolumeAccessTraceEventSummary] {
        store.events.filter { isPath($0.path, inside: path) && ($0.category == .read || $0.category == .write) }
    }

    private var recentEvents: [VolumeAccessTraceEventSummary] {
        Array(relevantEvents.sorted { $0.timestamp > $1.timestamp }.prefix(5))
    }

    private var processes: [DirectoryProcessSummary] {
        var grouped: [String: DirectoryProcessSummary] = [:]
        for event in relevantEvents {
            let key = event.process.stableID
            var current = grouped[key] ?? DirectoryProcessSummary(id: key, name: event.process.displayName, eventCount: 0, isWrite: false)
            current.eventCount += 1
            current.isWrite = current.isWrite || event.category == .write
            grouped[key] = current
        }
        return grouped.values.sorted { ($0.eventCount, $0.name) > ($1.eventCount, $1.name) }.prefix(5).map { $0 }
    }

    private var displayName: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func isPath(_ candidate: String, inside root: String) -> Bool {
        let candidate = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let root = URL(fileURLWithPath: root).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

private struct DirectoryProcessSummary: Identifiable {
    let id: String
    let name: String
    var eventCount: Int
    var isWrite: Bool
}

private struct DirectoryCoverageNoteView: View {
    let coverage: FileAccessTraceCoverage

    var body: some View {
        let complete = coverage == .complete
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: complete ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(complete ? InstrumentDesign.ColorRole.healthy : .orange)
                .accessibilityHidden(true)
            Text(complete
                ? L10n.text("这里显示成功捕获的系统请求字节，不等同于物理磁盘吞吐。")
                : L10n.text("当前事件量较高，部分记录已跳过；排行结果带有覆盖缺口。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(complete ? InstrumentDesign.ColorRole.healthy : .orange)
                .frame(width: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DirectoryCompositionView: View {
    let store: VolumeAccessTraceStore

    var body: some View {
        DirectoryReadWriteComposition(
            readBytes: store.requestedReadBytes ?? 0,
            writeBytes: store.requestedWriteBytes ?? 0
        )
    }
}

private struct DirectoryGuardRuleRow: View {
    let rule: DirectoryGuardRule
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: rule.isEnabled ? "folder.fill" : "folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(rule.isEnabled ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    (rule.isEnabled ? Color.accentColor : Color.secondary).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(rule.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.path)
                HStack(spacing: 6) {
                    ruleLabel(rule.operation.title, color: operationColor)
                    ruleLabel(expectedProgramsSummary, color: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle(
                L10n.text("启用此目录"),
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in onToggle(newValue) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L10n.text("启用此目录"))
            .accessibilityLabel(L10n.text("启用此目录"))

            HStack(spacing: 2) {
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false, tint: .blue))
                .help(L10n.text("编辑守护目录"))
                .accessibilityLabel(L10n.text("编辑守护目录"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(AppIconButtonStyle(size: 28, isFramed: false, tint: .red))
                .help(L10n.text("删除守护目录"))
                .accessibilityLabel(L10n.text("删除守护目录"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(rule.isEnabled ? 1 : 0.64)
        .accessibilityElement(children: .contain)
    }

    private var displayName: String {
        let name = URL(fileURLWithPath: rule.path).lastPathComponent
        return name.isEmpty ? rule.path : name
    }

    private var operationColor: Color {
        switch rule.operation {
        case .readWrite: Color.accentColor
        case .read: InstrumentDesign.ColorRole.diskRead
        case .write: InstrumentDesign.ColorRole.diskWrite
        }
    }

    private var expectedProgramsSummary: String {
        let count = rule.expectedProgramNames.count
        return count == 0
            ? L10n.text("所有程序都会标记")
            : L10n.format("%d 个预期程序", count)
    }

    private func ruleLabel(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.08), in: Capsule())
    }
}

private struct DirectoryGuardRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rule: DirectoryGuardRule
    @State private var expectedPrograms: [ExpectedProgramDraft]
    @State private var programNameDraft = ""
    @FocusState private var programFieldFocused: Bool

    let reservedPaths: Set<String>
    let onSave: (DirectoryGuardRule) -> Void

    init(
        rule: DirectoryGuardRule,
        reservedPaths: Set<String>,
        onSave: @escaping (DirectoryGuardRule) -> Void
    ) {
        _rule = State(initialValue: rule)
        _expectedPrograms = State(initialValue: rule.expectedProgramNames.map(ExpectedProgramDraft.init(name:)))
        self.reservedPaths = reservedPaths
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("配置守护目录"))
                        .font(.headline)
                    Text(L10n.text("这条规则只影响当前目录及其所有子目录。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("目录"))
                        .font(.callout.weight(.semibold))
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text(rule.path)
                            .font(.callout.monospaced().weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(rule.path)
                        Spacer(minLength: 8)
                        Button(action: chooseDirectory) {
                            Label(L10n.text("更换目录"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 42)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.74),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    if pathIsDuplicate {
                        Label(L10n.text("此目录已经在守护列表中"), systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.text("观察类型"))
                        .font(.callout.weight(.semibold))
                    GlassSegmentedControl(
                        L10n.text("观察类型"),
                        selection: $rule.operation
                    ) {
                        ForEach(DirectoryGuardOperation.allCases) { operation in
                            Text(operation.title).tag(operation)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("预期程序"))
                        .font(.callout.weight(.semibold))
                    Text(L10n.text("这些程序的访问不会列入守护结果。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField(L10n.text("输入程序名称"), text: $programNameDraft)
                            .textFieldStyle(.plain)
                            .focused($programFieldFocused)
                            .onSubmit(addExpectedProgram)
                            .frame(height: 34)
                        Button(action: addExpectedProgram) {
                            Label(L10n.text("添加程序"), systemImage: "plus")
                        }
                        .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                        .disabled(programNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("directory.guard.addExpectedProgram")
                    }
                    .padding(.horizontal, 10)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.74),
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                    }

                    if expectedPrograms.isEmpty {
                        Label(
                            L10n.text("尚未添加预期程序，所有程序访问都会列入结果。"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(expectedPrograms) { program in
                                HStack(spacing: 9) {
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 20)
                                        .accessibilityHidden(true)
                                    Text(program.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Button {
                                        removeExpectedProgram(program)
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(AppIconButtonStyle(size: 24, isFramed: false, tint: .secondary))
                                    .help(L10n.format("移除预期程序 %@", program.name))
                                    .accessibilityLabel(L10n.format("移除预期程序 %@", program.name))
                                }
                                .padding(.horizontal, 10)
                                .frame(minHeight: 34)
                                if program.id != expectedPrograms.last?.id {
                                    Divider().padding(.leading, 39)
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    }
                }

                Toggle(L10n.text("启用此目录"), isOn: $rule.isEnabled)
                    .toggleStyle(.switch)
            }
            .padding(18)

            Divider()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.text("取消")) { dismiss() }
                    .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                Button(L10n.text("保存")) {
                    var preparedRule = rule
                    preparedRule.setExpectedProgramNames(expectedPrograms.map(\.name))
                    onSave(preparedRule)
                    dismiss()
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                .disabled(pathIsDuplicate || rule.path.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560)
        .background(InstrumentDesign.Palette.canvasRaised)
        .accessibilityIdentifier("directory.guard.ruleEditor")
    }

    private func addExpectedProgram() {
        let normalized = programNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !expectedPrograms.contains(where: {
                  $0.name.caseInsensitiveCompare(normalized) == .orderedSame
              }) else { return }
        expectedPrograms.append(ExpectedProgramDraft(name: normalized))
        programNameDraft = ""
        programFieldFocused = true
    }

    private func removeExpectedProgram(_ program: ExpectedProgramDraft) {
        expectedPrograms.removeAll { $0.id == program.id }
    }

    private var pathIsDuplicate: Bool {
        reservedPaths.contains(VolumeAccessTraceTarget.canonicalPath(rule.path))
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择守护目录")
        panel.prompt = L10n.text("选择")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let path = VolumeAccessTraceTarget.canonicalPath(url.path)
            Task { @MainActor in rule.path = path }
        }
    }
}

private struct ExpectedProgramDraft: Identifiable, Equatable {
    let id = UUID()
    let name: String
}

private struct DirectoryGuardActivityView: View {
    let store: VolumeAccessTraceStore
    let guardEnabled: Bool
    let rules: [DirectoryGuardRule]
    let onAllowProgram: (UUID, String) -> Void
    let onTrace: (String) -> Void
    @State private var selectedProgram: DirectoryGuardProgramActivity?

    var body: some View {
        GlassSurface(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.person.crop")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(L10n.text("目录访问程序"))
                        .font(.headline)
                    Text(L10n.format("%d 个程序", activities.reduce(0) { $0 + $1.programs.count }))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        statusLegend(
                            title: "需关注",
                            color: .orange
                        )
                        statusLegend(
                            title: "符合预期",
                            color: InstrumentDesign.ColorRole.healthy
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                Divider()
                if activities.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(activities) { directory in
                            DirectoryGuardDirectoryNode(
                                directory: directory,
                                onSelectProgram: { selectedProgram = $0 }
                            )
                            if directory.id != activities.last?.id {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedProgram) { activity in
            DirectoryGuardProgramDetailView(
                activity: activity,
                onAllowProgram: onAllowProgram,
                onTrace: onTrace
            )
        }
    }

    private func statusLegend(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var activities: [DirectoryGuardDirectoryActivity] {
        DirectoryGuardMatcher.unexpectedProgramActivities(in: store.events, rules: rules)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let traceUnavailableMessage {
            VStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 27))
                    .foregroundStyle(.orange)
                Text(L10n.text("追踪组件未能启动"))
                    .font(.headline)
                Text(traceUnavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            .padding(20)
        } else {
            let presentation = DirectoryTracePresentationState.resolve(
                isCollecting: guardEnabled && store.state.isDirectoryTraceCollecting,
                firstEventAt: store.firstEventAt,
                elapsed: store.elapsed
            )
            switch presentation {
            case .waitingForActivity:
                DirectoryGuardWaitingStateView(directoryCount: enabledRuleCount)
            case .showingActivity, .noActivity:
                VStack(spacing: 9) {
                    Image(systemName: guardEnabled ? "checkmark.shield" : "shield")
                        .font(.system(size: 27))
                        .foregroundStyle(guardEnabled ? InstrumentDesign.ColorRole.healthy : .secondary.opacity(0.68))
                    Text(L10n.text(emptyStateTitle(for: presentation)))
                        .font(.headline)
                    Text(L10n.text(emptyStateDetail(for: presentation)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 430)
                }
                .frame(maxWidth: .infinity, minHeight: 210)
                .padding(20)
            }
        }
    }

    private var traceUnavailableMessage: String? {
        switch store.state {
        case .permissionRequired:
            return L10n.text("需要启用文件访问追踪")
        case .waitingForApproval:
            return L10n.text("在“登录项与扩展”中允许 FindDiskKiller 后返回这里，追踪会自动开始。")
        case .installationRequired:
            return L10n.text("需要先安装到应用程序文件夹")
        case .repairAvailable:
            return L10n.text("组件已启用但未能启动。请直接修复，无需重复切换系统设置；已有结果会保留。")
        case .failed(let message):
            return message
        case .unsupportedFormat:
            return L10n.text("当前 macOS 输出格式暂不受支持")
        default:
            return nil
        }
    }

    private func emptyStateTitle(for presentation: DirectoryTracePresentationState) -> String {
        if !guardEnabled { return "守护尚未启动" }
        if presentation == .noActivity { return "暂未观察到程序访问" }
        return "暂未发现需关注的程序"
    }

    private func emptyStateDetail(for presentation: DirectoryTracePresentationState) -> String {
        if !guardEnabled { return "已启用的目录访问将在启动守护后显示。" }
        if presentation == .noActivity { return "当前采集窗口没有目录读写；预期程序的访问不会列入这里。" }
        return "预期程序的访问已过滤；出现其他程序时会按目录汇总。"
    }

    private var enabledRuleCount: Int {
        rules.filter(\.isEnabled).count
    }

    private func directoryDisplayName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func programAccessibilityLabel(_ activity: DirectoryGuardProgramActivity) -> String {
        L10n.format(
            "%@，读取 %@，写入 %@",
            activity.process.displayName,
            accessSummary(count: activity.readEventCount, bytes: activity.readBytes, complete: activity.readBytesAreComplete),
            accessSummary(count: activity.writeEventCount, bytes: activity.writeBytes, complete: activity.writeBytesAreComplete)
        )
    }

    private func accessSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        L10n.format("%d 次 · %@", count, byteSummary(count: count, bytes: bytes, complete: complete))
    }

    private func byteSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        guard count > 0 else { return ByteRateFormatter.bytes(0) }
        guard complete else {
            return bytes == 0
                ? L10n.text("大小未知")
                : L10n.format("至少 %@", ByteRateFormatter.bytes(bytes))
        }
        return ByteRateFormatter.bytes(bytes)
    }
}

private struct DirectoryGuardDirectoryNode: View {
    let directory: DirectoryGuardDirectoryActivity
    let onSelectProgram: (DirectoryGuardProgramActivity) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 18)
                        .accessibilityHidden(true)

                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(directoryDisplayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(directory.rule.path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(directory.rule.path)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(L10n.format("%d 个程序", directory.programs.count))
                            .font(.caption.monospacedDigit().weight(.medium))
                        Text(L10n.format("%d 个事件 · %@", directory.eventCount, ByteRateFormatter.bytes(directory.requestedBytes)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text(isExpanded ? "折叠目录" : "展开目录"))
            .accessibilityLabel(L10n.text(isExpanded ? "折叠目录" : "展开目录"))
            .accessibilityValue(L10n.format("%d 个程序", directory.programs.count))

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(directory.programs.enumerated()), id: \.element.id) { index, activity in
                        HStack(spacing: 0) {
                            DirectoryGuardTreeBranch(isLast: index == directory.programs.count - 1)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.56), lineWidth: 1)
                                .frame(width: 34, height: 76)
                                .accessibilityHidden(true)

                            Button {
                                onSelectProgram(activity)
                            } label: {
                                DirectoryGuardProgramRow(activity: activity)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(programAccessibilityLabel(activity))
                        }
                        .padding(.leading, 24)
                        .background(Color.primary.opacity(0.012))
                    }
                }
            }
        }
    }

    private var directoryDisplayName: String {
        let name = URL(fileURLWithPath: directory.rule.path).lastPathComponent
        return name.isEmpty ? directory.rule.path : name
    }

    private func programAccessibilityLabel(_ activity: DirectoryGuardProgramActivity) -> String {
        L10n.format(
            "%@，读取 %@，写入 %@",
            activity.process.displayName,
            accessSummary(count: activity.readEventCount, bytes: activity.readBytes, complete: activity.readBytesAreComplete),
            accessSummary(count: activity.writeEventCount, bytes: activity.writeBytes, complete: activity.writeBytesAreComplete)
        )
    }

    private func accessSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        L10n.format("%d 次 · %@", count, byteSummary(count: count, bytes: bytes, complete: complete))
    }

    private func byteSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        guard count > 0 else { return ByteRateFormatter.bytes(0) }
        guard complete else {
            return bytes == 0
                ? L10n.text("大小未知")
                : L10n.format("至少 %@", ByteRateFormatter.bytes(bytes))
        }
        return ByteRateFormatter.bytes(bytes)
    }
}

private struct DirectoryGuardTreeBranch: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centerX = rect.midX
        let centerY = rect.midY
        path.move(to: CGPoint(x: centerX, y: rect.minY))
        path.addLine(to: CGPoint(x: centerX, y: isLast ? centerY : rect.maxY))
        path.move(to: CGPoint(x: centerX, y: centerY))
        path.addLine(to: CGPoint(x: rect.maxX, y: centerY))
        return path
    }
}

private struct DirectoryGuardProgramRow: View {
    let activity: DirectoryGuardProgramActivity
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            DirectoryGuardProcessIcon(process: activity.process, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.process.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(L10n.text(activity.isUnexpected ? "需关注" : "符合预期"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(activity.isUnexpected ? .orange : InstrumentDesign.ColorRole.healthy)
                    Text(L10n.text("点击查看事件明细"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            accessMetrics

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 76)
        .background(isHovered ? Color.accentColor.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var accessMetrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                metric(title: "读次数", value: L10n.number(activity.readEventCount), color: InstrumentDesign.ColorRole.diskRead)
                metric(title: "读数据量", value: byteSummary(count: activity.readEventCount, bytes: activity.readBytes, complete: activity.readBytesAreComplete), color: InstrumentDesign.ColorRole.diskRead)
                metric(title: "写次数", value: L10n.number(activity.writeEventCount), color: InstrumentDesign.ColorRole.diskWrite)
                metric(title: "写数据量", value: byteSummary(count: activity.writeEventCount, bytes: activity.writeBytes, complete: activity.writeBytesAreComplete), color: InstrumentDesign.ColorRole.diskWrite)
            }
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 16) {
                    metric(title: "读次数", value: L10n.number(activity.readEventCount), color: InstrumentDesign.ColorRole.diskRead)
                    metric(title: "读数据量", value: byteSummary(count: activity.readEventCount, bytes: activity.readBytes, complete: activity.readBytesAreComplete), color: InstrumentDesign.ColorRole.diskRead)
                }
                HStack(spacing: 16) {
                    metric(title: "写次数", value: L10n.number(activity.writeEventCount), color: InstrumentDesign.ColorRole.diskWrite)
                    metric(title: "写数据量", value: byteSummary(count: activity.writeEventCount, bytes: activity.writeBytes, complete: activity.writeBytesAreComplete), color: InstrumentDesign.ColorRole.diskWrite)
                }
            }
        }
        .frame(minWidth: 338, alignment: .trailing)
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func byteSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        guard count > 0 else { return ByteRateFormatter.bytes(0) }
        guard complete else {
            return bytes == 0
                ? L10n.text("大小未知")
                : L10n.format("至少 %@", ByteRateFormatter.bytes(bytes))
        }
        return ByteRateFormatter.bytes(bytes)
    }
}

private struct DirectoryGuardProgramDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let activity: DirectoryGuardProgramActivity
    let onAllowProgram: (UUID, String) -> Void
    let onTrace: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DirectoryGuardProcessIcon(process: activity.process, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("程序访问详情"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(activity.process.displayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(activity.rule.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(activity.rule.path)
                }
                Spacer(minLength: 12)
                Button {
                    onAllowProgram(activity.rule.id, activity.process.displayName)
                    dismiss()
                } label: {
                    Label(L10n.text("设为预期"), systemImage: "checkmark.circle")
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                Button {
                    dismiss()
                    onTrace(activity.rule.path)
                } label: {
                    Label(L10n.text("实时程序追踪"), systemImage: "scope")
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))
                Button {
                    dismiss()
                } label: {
                    Label(L10n.text("关闭"), systemImage: "xmark")
                }
                .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("directory.guard.programDetail.close")
            }
            .padding(18)

            Divider()
            HStack(spacing: 20) {
                detailMetric(
                    title: "读次数",
                    value: L10n.number(activity.readEventCount),
                    color: InstrumentDesign.ColorRole.diskRead
                )
                detailMetric(
                    title: "读数据量",
                    value: byteSummary(
                        count: activity.readEventCount,
                        bytes: activity.readBytes,
                        complete: activity.readBytesAreComplete
                    ),
                    color: InstrumentDesign.ColorRole.diskRead
                )
                detailMetric(
                    title: "写次数",
                    value: L10n.number(activity.writeEventCount),
                    color: InstrumentDesign.ColorRole.diskWrite
                )
                detailMetric(
                    title: "写数据量",
                    value: byteSummary(
                        count: activity.writeEventCount,
                        bytes: activity.writeBytes,
                        complete: activity.writeBytesAreComplete
                    ),
                    color: InstrumentDesign.ColorRole.diskWrite
                )
                detailMetric(
                    title: "事件",
                    value: L10n.number(activity.eventCount),
                    color: .secondary
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider()
            HStack {
                Text(L10n.text("事件列表"))
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()
            if activity.eventMatches.isEmpty {
                ContentUnavailableView(
                    L10n.text("当前没有事件明细"),
                    systemImage: "list.bullet.rectangle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(activity.eventMatches) {
                    TableColumn(L10n.text("时间")) { match in
                        Text(match.event.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 92, ideal: 112)
                    TableColumn(L10n.text("事件")) { match in
                        let isWrite = match.event.category == .write
                        Label(
                            L10n.text(isWrite ? "写入" : "读取"),
                            systemImage: isWrite ? "arrow.up" : "arrow.down"
                        )
                        .foregroundStyle(isWrite ? InstrumentDesign.ColorRole.diskWrite : InstrumentDesign.ColorRole.diskRead)
                    }
                    .width(min: 74, ideal: 88)
                    TableColumn(L10n.text("字节")) { match in
                        Text(match.event.requestedBytes.map(ByteRateFormatter.bytes) ?? L10n.text("不可用"))
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 80, ideal: 96)
                    TableColumn(L10n.text("文件")) { match in
                        Text(match.event.path)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(match.event.path)
                    }
                    .width(min: 300, ideal: 470)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(InstrumentDesign.Palette.canvasRaised)
        .accessibilityIdentifier("directory.guard.programDetail")
    }

    private func detailMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func byteSummary(count: Int, bytes: UInt64, complete: Bool) -> String {
        guard count > 0 else { return ByteRateFormatter.bytes(0) }
        guard complete else {
            return bytes == 0
                ? L10n.text("大小未知")
                : L10n.format("至少 %@", ByteRateFormatter.bytes(bytes))
        }
        return ByteRateFormatter.bytes(bytes)
    }
}

private struct DirectoryGuardProcessIcon: View {
    let process: VolumeAccessTraceProcessReference
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.18)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: process.stableID) {
            guard let pid = process.pid else { return }
            image = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        }
    }
}

private struct DirectoryGuardWaitingStateView: View {
    let directoryCount: Int

    var body: some View {
        VStack(spacing: 11) {
            Image(systemName: "shield.checkered")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            ProgressView().controlSize(.small)
            Text(L10n.text("正在建立目录守护"))
                .font(.headline)
            Text(L10n.text("首次读写可能需要几秒；符合规则的事件出现后会自动显示。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(
                L10n.format("正在观察 %d 个目录", directoryCount),
                systemImage: "folder"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 238)
        .padding(20)
        .accessibilityElement(children: .combine)
    }
}

private struct DirectoryRankedRow: Identifiable {
    let rank: Int
    let directory: VolumeAccessTraceDirectorySummary

    var id: String { directory.id }
}

private struct DirectoryMetric: View {
    let title: String
    let value: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 23, height: 23)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DirectoryUsageColumn: View {
    let title: String
    let value: UInt64
    let color: Color
    let fraction: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(ByteRateFormatter.bytes(value))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.13))
                Capsule()
                    .fill(color.opacity(0.72))
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: max(0.02, min(1, fraction)), y: 1, anchor: .leading)
            }
            .frame(width: 112, height: 3)
        }
        .frame(width: 112, alignment: .trailing)
    }
}

private struct DirectoryCompactUsageColumn: View {
    let readBytes: UInt64
    let writeBytes: UInt64

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            compactMetric(
                title: L10n.text("读取"),
                value: readBytes,
                color: InstrumentDesign.ColorRole.diskRead
            )
            compactMetric(
                title: L10n.text("写入"),
                value: writeBytes,
                color: InstrumentDesign.ColorRole.diskWrite
            )
        }
        .frame(width: 96, alignment: .trailing)
    }

    private func compactMetric(title: String, value: UInt64, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(ByteRateFormatter.bytes(value))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.caption2.monospacedDigit().weight(.medium))
    }
}

private struct DirectoryDiagnosticButtonStyle: ButtonStyle {
    let isDestructive: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        DirectoryDiagnosticButtonBody(
            label: configuration.label,
            isDestructive: isDestructive,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct DirectoryDiagnosticButtonBody<Label: View>: View {
    let label: Label
    let isDestructive: Bool
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        label
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .frame(minHeight: 42)
            .foregroundStyle(.white)
            .background {
                shape
                    .fill(baseColor)
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), .clear, Color.black.opacity(0.10)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.20), lineWidth: 0.7)
            }
            .visualEffectShadow(color: baseColor.opacity(0.34), radius: 6, y: 3)
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.12), value: isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var baseColor: Color {
        if isDestructive {
            return isHovering ? Color.red.opacity(0.96) : Color.red.opacity(0.88)
        }
        return isHovering ? Color.accentColor.opacity(0.96) : Color.accentColor.opacity(0.86)
    }
}

private struct DirectoryChartLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            legendItem("读取", color: InstrumentDesign.ColorRole.diskRead)
            legendItem("写入", color: InstrumentDesign.ColorRole.diskWrite)
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 13, height: 3)
                .accessibilityHidden(true)
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DirectoryRateTimelineChart: View {
    let points: [VolumeAccessTraceRatePoint]

    @State private var hoverDate: Date?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        Chart(points) { point in
            AreaMark(
                x: .value(L10n.text("时间"), point.timestamp),
                y: .value(L10n.text("读取"), point.readBytesPerSecond),
                series: .value(L10n.text("系列"), "directory-read-area")
            )
            .foregroundStyle(InstrumentDesign.ColorRole.diskRead.opacity(0.10))

            LineMark(
                x: .value(L10n.text("时间"), point.timestamp),
                y: .value(L10n.text("读取"), point.readBytesPerSecond),
                series: .value(L10n.text("系列"), "directory-read")
            )
                .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.linear)

            AreaMark(
                x: .value(L10n.text("时间"), point.timestamp),
                y: .value(L10n.text("写入"), point.writeBytesPerSecond),
                series: .value(L10n.text("系列"), "directory-write-area")
            )
            .foregroundStyle(InstrumentDesign.ColorRole.diskWrite.opacity(0.10))

            LineMark(
                x: .value(L10n.text("时间"), point.timestamp),
                y: .value(L10n.text("写入"), point.writeBytesPerSecond),
                series: .value(L10n.text("系列"), "directory-write")
            )
                .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .interpolationMethod(.linear)

            if selectedPoint?.timestamp == point.timestamp {
                RuleMark(x: .value(L10n.text("选中时间"), point.timestamp))
                    .foregroundStyle(.secondary.opacity(0.45))
                PointMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("读取"), point.readBytesPerSecond)
                )
                .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                PointMark(
                    x: .value(L10n.text("时间"), point.timestamp),
                    y: .value(L10n.text("写入"), point.writeBytesPerSecond)
                )
                .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
            }
        }
        .chartLegend(.hidden)
        .resourceRateAxis()
        .resourceTimeAxis()
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .chartHoverSelection($hoverDate, location: $hoverLocation)
        .frame(height: 210)
        .overlay {
            if points.count < 2 {
                Label(
                    L10n.text("当前没有观察到读写请求"),
                    systemImage: "waveform.path.ecg"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if let point = selectedPoint, let hoverLocation {
                DirectoryRateChartTooltip(point: point, pointer: hoverLocation)
            }
        }
    }

    private var selectedPoint: VolumeAccessTraceRatePoint? {
        guard let hoverDate else { return nil }
        return points.min {
            abs($0.timestamp.timeIntervalSince(hoverDate))
                < abs($1.timestamp.timeIntervalSince(hoverDate))
        }
    }
}

private struct DirectoryRateChartTooltip: View {
    let point: VolumeAccessTraceRatePoint
    let pointer: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let size = CGSize(width: 142, height: 74)
            let proposedX = pointer.x + size.width + 12 < geometry.size.width
                ? pointer.x + size.width / 2 + 10
                : pointer.x - size.width / 2 - 10
            let x = min(max(size.width / 2 + 4, proposedX), geometry.size.width - size.width / 2 - 4)
            let proposedY = pointer.y > size.height + 14
                ? pointer.y - size.height / 2 - 10
                : pointer.y + size.height / 2 + 10
            let y = min(max(size.height / 2 + 4, proposedY), geometry.size.height - size.height / 2 - 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(point.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption.weight(.semibold))
                tooltipRow("读取", value: point.readBytesPerSecond, color: InstrumentDesign.ColorRole.diskRead)
                tooltipRow("写入", value: point.writeBytesPerSecond, color: InstrumentDesign.ColorRole.diskWrite)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .visualEffectShadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .position(x: x, y: y)
        }
        .allowsHitTesting(false)
    }

    private func tooltipRow(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(L10n.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(ByteRateFormatter.rate(value)).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct DirectoryReadWriteComposition: View {
    let readBytes: UInt64
    let writeBytes: UInt64

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if totalBytes == 0 {
                    Circle()
                        .stroke(Color.secondary.opacity(0.14), lineWidth: 14)
                        .padding(12)
                } else {
                    Chart {
                        SectorMark(
                            angle: .value(L10n.text("累计请求读取"), readBytes),
                            innerRadius: .ratio(0.68),
                            angularInset: 1.5
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.diskRead)
                        SectorMark(
                            angle: .value(L10n.text("累计请求写入"), writeBytes),
                            innerRadius: .ratio(0.68),
                            angularInset: 1.5
                        )
                        .foregroundStyle(InstrumentDesign.ColorRole.diskWrite)
                    }
                    .chartLegend(.hidden)
                }

                VStack(spacing: 2) {
                    Text(totalBytes == 0 ? "--" : ByteRateFormatter.bytes(totalBytes))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(L10n.text("累计请求"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 86)
            }
            .frame(width: 138, height: 138)

            VStack(spacing: 7) {
                compositionRow(
                    "累计请求读取",
                    value: readBytes,
                    color: InstrumentDesign.ColorRole.diskRead
                )
                compositionRow(
                    "累计请求写入",
                    value: writeBytes,
                    color: InstrumentDesign.ColorRole.diskWrite
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var totalBytes: UInt64 {
        let result = readBytes.addingReportingOverflow(writeBytes)
        return result.overflow ? UInt64.max : result.partialValue
    }

    private func compositionRow(_ title: String, value: UInt64, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(ByteRateFormatter.bytes(value))
                .font(.caption2.monospacedDigit().weight(.medium))
        }
    }
}

private struct DirectoryActivityBar: Identifiable {
    let id: String
    let directory: String
    let series: String
    let value: Double
}

private struct DirectoryTopActivityChart: View {
    let rows: [DirectoryRankedRow]

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value(L10n.text("目录读写排行"), bar.value),
                y: .value(L10n.text("目录"), bar.directory)
            )
            .foregroundStyle(by: .value(L10n.text("系列"), bar.series))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale([
            L10n.text("读取"): InstrumentDesign.ColorRole.diskRead,
            L10n.text("写入"): InstrumentDesign.ColorRole.diskWrite
        ])
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(position: .bottom) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(ByteRateFormatter.approximateBytes(bytes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let directory = value.as(String.self) {
                        Text(directory)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(Color.secondary.opacity(0.035)) }
        .frame(height: max(170, CGFloat(rows.count) * 31))
    }

    private var bars: [DirectoryActivityBar] {
        rows.flatMap { row in
            let name = directoryDisplayName(row.directory.path)
            let label = "\(L10n.number(row.rank))  \(name)"
            return [
                DirectoryActivityBar(
                    id: "\(row.id):read",
                    directory: label,
                    series: L10n.text("读取"),
                    value: Double(row.directory.requestedReadBytes)
                ),
                DirectoryActivityBar(
                    id: "\(row.id):write",
                    directory: label,
                    series: L10n.text("写入"),
                    value: Double(row.directory.requestedWriteBytes)
                )
            ]
        }
    }

    private func directoryDisplayName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
