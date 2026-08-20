import Foundation
import FindDiskKillerCore
import Testing
@testable import FindDiskKillerApp

@Test func directoryTracePresentationWaitsForTheFirstEventDuringStartup() {
    let state = DirectoryTracePresentationState.resolve(
        isCollecting: true,
        firstEventAt: nil,
        elapsed: 2
    )

    #expect(state == .waitingForActivity)
}

@Test func directoryTracePresentationMovesToNoActivityAfterTheInitialWindow() {
    let state = DirectoryTracePresentationState.resolve(
        isCollecting: true,
        firstEventAt: nil,
        elapsed: DirectoryTracePresentationState.initialWaitWindow
    )

    #expect(state == .noActivity)
}

@Test func directoryTracePresentationShowsActivityEvenAfterTheWaitWindow() {
    let state = DirectoryTracePresentationState.resolve(
        isCollecting: true,
        firstEventAt: Date(timeIntervalSince1970: 100),
        elapsed: 1
    )

    #expect(state == .showingActivity)
}

@Test func directoryTracePresentationDoesNotWaitWhenTraceIsNotCollecting() {
    let state = DirectoryTracePresentationState.resolve(
        isCollecting: false,
        firstEventAt: nil,
        elapsed: 0
    )

    #expect(state == .noActivity)
}

@Test func directoryDetailPresentationNeverAddsASecondColumnAtCompactWidths() {
    #expect(DirectoryWorkspaceLayout.detailPresentation(for: 759) == .sheet)
    #expect(DirectoryWorkspaceLayout.primaryContentWidth(for: 759) == 759)
}

@Test func directoryDetailUsesAnOverlayWithoutCompressingThePrimaryColumn() {
    #expect(DirectoryWorkspaceLayout.detailPresentation(for: 1_000) == .overlay)
    #expect(DirectoryWorkspaceLayout.primaryContentWidth(for: 1_000) == 1_000)
}

@Test func directoryDetailOnlySplitsWhenBothColumnsFit() {
    let width = DirectoryWorkspaceLayout.splitDetailMinimumWidth
    #expect(DirectoryWorkspaceLayout.detailPresentation(for: width) == .split)
    #expect(
        DirectoryWorkspaceLayout.primaryContentWidth(for: width)
            == width
                - DirectoryWorkspaceLayout.detailWidth
                - DirectoryWorkspaceLayout.splitDividerWidth
    )
}

@Test func directoryTableChoosesCompactRowsBelowItsWideLayoutContract() {
    #expect(DirectoryWorkspaceLayout.usesCompactTable(for: 699))
    #expect(!DirectoryWorkspaceLayout.usesCompactTable(for: 700))
}

@Test func directoryRankingIsLimitedToTopTenRows() {
    #expect(DirectoryWorkspaceLayout.maximumRankedDirectories == 10)
}

@Test func directoryGuardPersistenceMigratesThePreviousSingleRule() throws {
    let rules = DirectoryGuardRulePersistence.load(
        data: Data(),
        legacyPath: "/Users/example/Work",
        legacyExpectedPrograms: "Xcode, swift",
        legacyOperationRaw: DirectoryGuardOperation.write.rawValue
    )

    let rule = try #require(rules.first)
    #expect(rules.count == 1)
    #expect(rule.path == "/Users/example/Work")
    #expect(rule.operation == .write)
    #expect(rule.expectedProgramNames == ["Xcode", "swift"])
    #expect(rule.isEnabled)
}

@Test func directoryGuardPersistenceRoundTripsMultipleRules() {
    let rules = [
        DirectoryGuardRule(path: "/Users/example/Work", operation: .read),
        DirectoryGuardRule(
            path: "/Volumes/JianDisk/Archive",
            operation: .write,
            expectedPrograms: "backupd",
            isEnabled: false
        ),
    ]

    let decoded = DirectoryGuardRulePersistence.load(
        data: DirectoryGuardRulePersistence.encode(rules),
        legacyPath: "",
        legacyExpectedPrograms: "",
        legacyOperationRaw: ""
    )
    #expect(decoded == rules)
}

@Test func directoryGuardMatcherUsesTheMostSpecificEnabledRule() throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    var aggregator = VolumeAccessTraceAggregator(
        target: VolumeAccessTraceTarget(
            volumeID: "startup",
            name: "Macintosh HD",
            mountPath: "/",
            scopePath: "/Users/example/Work"
        ),
        startedAt: startedAt
    )
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(1),
        operation: "write",
        category: .write,
        requestedBytes: 1_024,
        path: "/Users/example/Work/Private/state.db",
        process: VolumeAccessTraceProcessReference(
            pid: 42,
            startAbstime: 1,
            displayName: "Xcode"
        )
    ))
    let parent = DirectoryGuardRule(
        path: "/Users/example/Work",
        expectedPrograms: "Xcode"
    )
    let child = DirectoryGuardRule(path: "/Users/example/Work/Private")

    let match = try #require(DirectoryGuardMatcher.unexpectedEvents(
        in: aggregator.snapshot().events,
        rules: [parent, child]
    ).first)
    #expect(match.rule.id == child.id)
}

@Test func directoryGuardMatcherAppliesOperationAndProgramPerRule() throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    var aggregator = VolumeAccessTraceAggregator(
        target: VolumeAccessTraceTarget(
            volumeID: "startup",
            name: "Macintosh HD",
            mountPath: "/",
            scopePath: "/Users/example/Work"
        ),
        startedAt: startedAt
    )
    let process = VolumeAccessTraceProcessReference(
        pid: 42,
        startAbstime: 1,
        displayName: "backupd"
    )
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(1),
        operation: "read",
        category: .read,
        requestedBytes: 1_024,
        path: "/Users/example/Work/read.db",
        process: process
    ))
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(2),
        operation: "write",
        category: .write,
        requestedBytes: 1_024,
        path: "/Users/example/Work/write.db",
        process: process
    ))
    let rule = DirectoryGuardRule(
        path: "/Users/example/Work",
        operation: .write,
        expectedPrograms: "BACKUPD"
    )

    #expect(DirectoryGuardMatcher.unexpectedEvents(
        in: aggregator.snapshot().events,
        rules: [rule]
    ).isEmpty)
}

@Test func directoryGuardRuleNormalizesExpectedProgramsWithoutCommaEditing() {
    let rule = DirectoryGuardRule(
        path: "/Users/example/Work",
        expectedPrograms: "Xcode, xcode,  swift  ,"
    )

    #expect(rule.expectedProgramNames == ["Xcode", "swift"])

    var editable = rule
    editable.setExpectedProgramNames(["backupd", "BACKUPD", " ", "Xcode"])
    #expect(editable.expectedPrograms == "backupd, Xcode")
}

@Test func directoryGuardProgramActivitiesAggregateExpectedAndUnexpectedPrograms() throws {
    let startedAt = Date(timeIntervalSince1970: 100)
    let target = VolumeAccessTraceTarget(
        volumeID: "startup",
        name: "Macintosh HD",
        mountPath: "/",
        scopePath: "/Users/example/Work"
    )
    var aggregator = VolumeAccessTraceAggregator(target: target, startedAt: startedAt)
    let expected = VolumeAccessTraceProcessReference(pid: 42, startAbstime: 1, displayName: "backupd")
    let unexpected = VolumeAccessTraceProcessReference(pid: 43, startAbstime: 1, displayName: "curl")
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(1),
        operation: "read",
        category: .read,
        requestedBytes: 100,
        path: "/Users/example/Work/state.db",
        process: expected
    ))
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(2),
        operation: "write",
        category: .write,
        requestedBytes: 300,
        path: "/Users/example/Work/state.db",
        process: expected
    ))
    aggregator.ingest(VolumeAccessTraceEvent(
        timestamp: startedAt.addingTimeInterval(3),
        operation: "read",
        category: .read,
        requestedBytes: 500,
        path: "/Users/example/Work/cache.db",
        process: unexpected
    ))
    let rule = DirectoryGuardRule(path: "/Users/example/Work", expectedPrograms: "backupd")

    let directory = try #require(
        DirectoryGuardMatcher.programActivities(in: aggregator.snapshot().events, rules: [rule]).first
    )
    #expect(directory.programs.count == 2)
    let expectedActivity = try #require(directory.programs.first(where: { $0.process.displayName == "backupd" }))
    #expect(expectedActivity.readEventCount == 1)
    #expect(expectedActivity.writeEventCount == 1)
    #expect(expectedActivity.readBytes == 100)
    #expect(expectedActivity.writeBytes == 300)
    #expect(!expectedActivity.isUnexpected)

    let unexpectedActivity = try #require(directory.programs.first(where: { $0.process.displayName == "curl" }))
    #expect(unexpectedActivity.readEventCount == 1)
    #expect(unexpectedActivity.readBytes == 500)
    #expect(unexpectedActivity.isUnexpected)
}
