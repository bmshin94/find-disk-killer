import AppKit
import FindDiskKillerCore
import SwiftUI

// MARK: - Model

struct WorkspaceRepositoryItem: Identifiable {
    enum Kind {
        case repository
        case worktree
        case location
    }

    let node: StorageResourceNode
    let path: String
    let name: String
    let branch: String?
    let kind: Kind
    let worktrees: [WorkspaceRepositoryItem]

    var id: String { node.id }

    /// Analyzer-merged repository nodes already include their linked
    /// worktree bytes, so a repository row shows the real total footprint
    /// (main checkout + all linked worktrees).
}

struct WorkspaceRepositoryGroup: Identifiable {
    let id: String
    let path: String
    let items: [WorkspaceRepositoryItem]

    var allocatedBytes: UInt64 {
        items.reduce(UInt64.zero) { partial, item in
            let sum = partial.addingReportingOverflow(item.node.allocatedBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    var repositoryCount: Int {
        items.reduce(0) { $0 + ($1.kind == .repository ? 1 : 0) }
    }

    var worktreeCount: Int {
        items.reduce(0) { $0 + $1.worktrees.count + ($1.kind == .worktree ? 1 : 0) }
    }
}

// MARK: - Grouping

enum WorkspaceRepositoryGrouping {
    static func groups(nodes: [StorageResourceNode]) -> [WorkspaceRepositoryGroup] {
        var flat: [(groupPath: String, item: WorkspaceRepositoryItem)] = []

        func makeItem(_ node: StorageResourceNode, path: String) -> WorkspaceRepositoryItem {
            let worktrees = node.children
                .filter { $0.kind == .worktree }
                .compactMap { child -> WorkspaceRepositoryItem? in
                    guard let childPath = WorkspaceRepositoryGrouping.path(from: child) else { return nil }
                    return WorkspaceRepositoryItem(
                        node: child,
                        path: childPath,
                        name: URL(fileURLWithPath: childPath).lastPathComponent,
                        branch: WorkspaceRepositoryGrouping.branch(from: child),
                        kind: .worktree,
                        worktrees: []
                    )
                }
            let kind: WorkspaceRepositoryItem.Kind
            switch node.kind {
            case .repository: kind = .repository
            case .worktree: kind = .worktree
            default: kind = .location
            }
            return WorkspaceRepositoryItem(
                node: node,
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                branch: WorkspaceRepositoryGrouping.branch(from: node),
                kind: kind,
                worktrees: worktrees
            )
        }

        func collect(_ node: StorageResourceNode) {
            switch node.kind {
            case .repository, .worktree:
                guard let path = WorkspaceRepositoryGrouping.path(from: node) else { return }
                flat.append((parentDirectory(of: path), makeItem(node, path: path)))
            case .location:
                if node.id.hasPrefix("workspace.parent.") {
                    for child in node.children { collect(child) }
                } else if let path = WorkspaceRepositoryGrouping.path(from: node) {
                    // A configured workspace root or another standalone
                    // location: keep it as its own group.
                    flat.append((path, makeItem(node, path: path)))
                }
            default:
                break
            }
        }

        for node in nodes { collect(node) }

        var grouped: [String: [WorkspaceRepositoryItem]] = [:]
        for entry in flat {
            grouped[entry.groupPath, default: []].append(entry.item)
        }

        return grouped.map { path, items in
            WorkspaceRepositoryGroup(
                id: "workspace.group.\(stableHash(path))",
                path: path,
                items: items.sorted { lhs, rhs in
                    if lhs.node.allocatedBytes != rhs.node.allocatedBytes {
                        return lhs.node.allocatedBytes > rhs.node.allocatedBytes
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.allocatedBytes != rhs.allocatedBytes {
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    /// Repository and worktree nodes carry their full path as the last
    /// " · "-separated component of `detail` (for example
    /// "主仓库 · main · /Users/me/code/app").
    static func path(from node: StorageResourceNode) -> String? {
        guard let detail = node.detail else { return nil }
        let parts = detail.components(separatedBy: " · ")
        guard let candidate = parts.last, candidate.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: candidate).standardizedFileURL.path
    }

    static func branch(from node: StorageResourceNode) -> String? {
        guard let detail = node.detail else { return nil }
        let parts = detail.components(separatedBy: " · ")
        guard parts.count >= 3 else { return nil }
        let branch = parts.dropFirst().dropLast().joined(separator: " · ")
        return branch.isEmpty ? nil : branch
    }

    static func parentDirectory(of path: String) -> String {
        URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
    }

    private static func stableHash(_ path: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Shared display helpers

private enum WorkspaceDisplay {
    static let homeDirectory = NSHomeDirectory()

    static func displayPath(_ path: String) -> String {
        let home = homeDirectory
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func shareText(_ bytes: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return L10n.percent(0) }
        return L10n.percent(Double(bytes) / Double(total))
    }

    static func share(_ bytes: UInt64, of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }

    static func selectionSymbol(selectedCount: Int, totalCount: Int) -> String {
        if selectedCount == 0 { return "square" }
        if selectedCount == totalCount { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    static func cleanupHelp(for node: StorageResourceNode) -> String {
        guard let target = node.cleanupTarget else {
            return node.isProtected
                ? L10n.text("此资源受保护或必须通过官方工具管理")
                : L10n.text("此资源不提供直接清理")
        }
        switch target {
        case .trashRepository:
            return L10n.text("将整个主仓库移入废纸篓；不会删除同目录下的其它仓库")
        case .removeGitWorktree:
            return L10n.text("通过 git 移除该 Worktree，保留主仓库；含未提交更改或未跟踪文件时将拒绝执行")
        default:
            return L10n.text("选择此资源进行清理")
        }
    }
}

// MARK: - Sort

enum WorkspaceRepositorySort: String, CaseIterable, Identifiable {
    case bySize
    case byPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bySize: L10n.text("按占用")
        case .byPath: L10n.text("按路径")
        }
    }
}

// MARK: - View

struct WorkspaceRepositoriesView: View {
    let projection: StorageResourceTreeIndex
    let result: StorageSourceResult
    let pendingSynchronizationIDs: Set<String>
    @Binding var selectedIDs: Set<String>
    let onSelectionInteraction: () -> Void

    /// Built once per projection revision; all body evaluations reuse it.
    @State private var groups: [WorkspaceRepositoryGroup]
    @State private var query = ""
    @State private var sort: WorkspaceRepositorySort = .bySize
    @State private var expandedGroupIDs: Set<String> = []
    @State private var expandedItemIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        projection: StorageResourceTreeIndex,
        result: StorageSourceResult,
        pendingSynchronizationIDs: Set<String>,
        selectedIDs: Binding<Set<String>>,
        onSelectionInteraction: @escaping () -> Void
    ) {
        self.projection = projection
        self.result = result
        self.pendingSynchronizationIDs = pendingSynchronizationIDs
        _selectedIDs = selectedIDs
        self.onSelectionInteraction = onSelectionInteraction
        _groups = State(initialValue: WorkspaceRepositoryGrouping.groups(nodes: projection.nodes))
    }

    private var totalBytes: UInt64 {
        groups.reduce(UInt64.zero) { partial, group in
            let sum = partial.addingReportingOverflow(group.allocatedBytes)
            return sum.overflow ? .max : sum.partialValue
        }
    }

    private var displayedGroups: [WorkspaceRepositoryGroup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [WorkspaceRepositoryGroup]
        if trimmed.isEmpty {
            base = groups
        } else {
            var filtered: [WorkspaceRepositoryGroup] = []
            for group in groups {
                let pathMatches = group.path.localizedCaseInsensitiveContains(trimmed)
                let items = group.items.compactMap { item -> WorkspaceRepositoryItem? in
                    let selfMatches = pathMatches
                        || item.name.localizedCaseInsensitiveContains(trimmed)
                        || item.path.localizedCaseInsensitiveContains(trimmed)
                        || (item.branch?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    let matchingWorktrees = item.worktrees.filter { worktree in
                        worktree.name.localizedCaseInsensitiveContains(trimmed)
                            || worktree.path.localizedCaseInsensitiveContains(trimmed)
                            || (worktree.branch?.localizedCaseInsensitiveContains(trimmed) ?? false)
                    }
                    if selfMatches {
                        return item
                    }
                    if matchingWorktrees.isEmpty { return nil }
                    return WorkspaceRepositoryItem(
                        node: item.node,
                        path: item.path,
                        name: item.name,
                        branch: item.branch,
                        kind: item.kind,
                        worktrees: matchingWorktrees
                    )
                }
                if pathMatches {
                    filtered.append(group)
                } else if !items.isEmpty {
                    filtered.append(WorkspaceRepositoryGroup(
                        id: group.id,
                        path: group.path,
                        items: items
                    ))
                }
            }
            base = filtered
        }
        switch sort {
        case .bySize:
            return base.sorted { lhs, rhs in
                if lhs.allocatedBytes != rhs.allocatedBytes {
                    return lhs.allocatedBytes > rhs.allocatedBytes
                }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        case .byPath:
            return base.sorted { lhs, rhs in
                let order = lhs.path.localizedStandardCompare(rhs.path)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.allocatedBytes > rhs.allocatedBytes
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statsStrip
            toolbar
            listSection
            footer
        }
        .onChange(of: projection.id) { _, _ in
            groups = WorkspaceRepositoryGrouping.groups(nodes: projection.nodes)
            expandedGroupIDs = []
            expandedItemIDs = []
        }
        .accessibilityIdentifier("workspace-repositories-view")
    }

    // MARK: Stats

    private var statsStrip: some View {
        HStack(spacing: 0) {
            statItem(
                title: L10n.text("仓库"),
                value: L10n.number(groups.reduce(0) { $0 + $1.repositoryCount }),
                symbol: "folder.badge.gearshape",
                accent: Color.accentColor
            )
            statDivider
            statItem(
                title: L10n.text("Worktree"),
                value: L10n.number(groups.reduce(0) { $0 + $1.worktreeCount }),
                symbol: "arrow.triangle.branch",
                accent: InstrumentDesign.ColorRole.memory
            )
            statDivider
            statItem(
                title: L10n.text("所在目录"),
                value: L10n.number(groups.count),
                symbol: "folder.fill",
                accent: InstrumentDesign.ColorRole.read
            )
            statDivider
            statItem(
                title: L10n.text("总占用"),
                value: AgentStorageSizeFormatter.string(totalBytes),
                symbol: "internaldrive.fill",
                accent: InstrumentDesign.ColorRole.cleanup
            )
        }
        .frame(height: 36)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.42),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.6)
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.6, height: 18)
            .padding(.vertical, 9)
            .accessibilityHidden(true)
    }

    private func statItem(
        title: String,
        value: String,
        symbol: String,
        accent: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 20, height: 20)
                .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption.monospaced().weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField
            GlassSegmentedControl("排序方式", selection: $sort) {
                ForEach(WorkspaceRepositorySort.allCases) { option in
                    Text(option.title)
                        .lineLimit(1)
                        .tag(option)
                }
            }
            .frame(width: 164)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                expandCollapseButton
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.text("搜索仓库路径或名称"), text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .accessibilityLabel(L10n.text("搜索仓库路径或名称"))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("清除搜索"))
                .accessibilityLabel(L10n.text("清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.48),
            in: RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
        )
        .overlay {
            RoundedRectangle(cornerRadius: InstrumentDesign.Radius.control)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6)
        }
        .frame(minWidth: 0, maxWidth: 400, alignment: .leading)
    }

    private var expandCollapseButton: some View {
        let isExpanded = isEverythingExpanded
        return Button {
            toggleEverything()
        } label: {
            Label(
                isExpanded ? L10n.text("全部折叠") : L10n.text("全部展开"),
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption.weight(.medium))
        }
        .buttonStyle(AppActionButtonStyle(kind: .secondary, size: .compact))
        .help(isExpanded ? L10n.text("全部折叠") : L10n.text("全部展开"))
        .accessibilityLabel(isExpanded ? L10n.text("全部折叠") : L10n.text("全部展开"))
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isEverythingExpanded: Bool {
        guard !displayedGroups.isEmpty else { return false }
        let groupIDs = Set(displayedGroups.map(\.id))
        guard groupIDs.isSubset(of: expandedGroupIDs) else { return false }
        let itemIDs = Set(
            displayedGroups.flatMap(\.items)
                .filter { !$0.worktrees.isEmpty }
                .map(\.id)
        )
        return itemIDs.isSubset(of: expandedItemIDs)
    }

    private func toggleEverything() {
        let groupIDs = Set(displayedGroups.map(\.id))
        let itemIDs = Set(
            displayedGroups.flatMap(\.items)
                .filter { !$0.worktrees.isEmpty }
                .map(\.id)
        )
        let shouldCollapse = expandedGroupIDs.isSuperset(of: groupIDs)
            && expandedItemIDs.isSuperset(of: itemIDs)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if shouldCollapse {
                expandedGroupIDs.subtract(groupIDs)
                expandedItemIDs.subtract(itemIDs)
            } else {
                expandedGroupIDs.formUnion(groupIDs)
                expandedItemIDs.formUnion(itemIDs)
            }
        }
    }

    // MARK: List

    @ViewBuilder
    private var listSection: some View {
        if groups.isEmpty {
            emptyAllState
        } else if displayedGroups.isEmpty {
            emptySearchState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(displayedGroups) { group in
                    WorkspaceGroupRow(
                        group: group,
                        isExpanded: expandedGroupIDs.contains(group.id) || isSearching,
                        totalBytes: totalBytes,
                        projection: projection,
                        pendingSynchronizationIDs: pendingSynchronizationIDs,
                        selectedIDs: $selectedIDs,
                        onSelectionInteraction: onSelectionInteraction,
                        onToggle: { toggleGroup(group) },
                        expandedItemIDs: expandedItemIDs,
                        isSearching: isSearching,
                        onToggleItem: { itemID in toggleItem(itemID) }
                    )
                }
            }
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.35),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var emptyAllState: some View {
        ContentUnavailableView {
            Label(L10n.text("当前分析未发现 Git 仓库"), systemImage: "arrow.triangle.branch")
        } description: {
            Text(L10n.text("仓库定位受完全磁盘访问范围限制；授权后可发现更多位置。"))
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .accessibilityIdentifier("workspace-repositories-empty")
    }

    private var emptySearchState: some View {
        ContentUnavailableView {
            Label(L10n.text("未找到匹配的仓库"), systemImage: "magnifyingglass")
        } description: {
            Text(L10n.text("尝试其他关键词或清除搜索。"))
        } actions: {
            Button(L10n.text("清除搜索")) { query = "" }
                .buttonStyle(AppActionButtonStyle(kind: .secondary))
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .accessibilityIdentifier("workspace-repositories-search-empty")
    }

    private func toggleGroup(_ group: WorkspaceRepositoryGroup) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if expandedGroupIDs.contains(group.id) {
                expandedGroupIDs.remove(group.id)
            } else {
                expandedGroupIDs.insert(group.id)
            }
        }
    }

    private func toggleItem(_ itemID: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            if expandedItemIDs.contains(itemID) {
                expandedItemIDs.remove(itemID)
            } else {
                expandedItemIDs.insert(itemID)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let diagnostic = result.inventoryDiagnostic {
                Label(L10n.text(diagnostic), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Label(
                    result.isComplete
                        ? L10n.text("本次读取范围完整")
                        : L10n.text("部分位置无法读取，容量可能偏低"),
                    systemImage: result.isComplete ? "checkmark.shield" : "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(result.isComplete ? Color.secondary : Color.orange)
                Label(
                    L10n.text("主仓库与 worktree 会按关系归组。当前仓库保持锁定；其他仓库只有在勾选并二次确认后才会移入废纸篓。"),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

// MARK: - Group row

private struct WorkspaceGroupRow: View {
    let group: WorkspaceRepositoryGroup
    let isExpanded: Bool
    let totalBytes: UInt64
    let projection: StorageResourceTreeIndex
    let pendingSynchronizationIDs: Set<String>
    @Binding var selectedIDs: Set<String>
    let onSelectionInteraction: () -> Void
    let onToggle: () -> Void
    let expandedItemIDs: Set<String>
    let isSearching: Bool
    let onToggleItem: (String) -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(isExpanded ? "折叠此目录" : "展开此目录"))
                .accessibilityLabel(L10n.text(isExpanded ? "折叠此目录" : "展开此目录"))

                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)

                Text(WorkspaceDisplay.displayPath(group.path))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                countSummary
                Text(AgentStorageSizeFormatter.string(group.allocatedBytes))
                    .font(.caption.monospaced().weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(WorkspaceDisplay.shareText(group.allocatedBytes, of: totalBytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                aggregateCheckbox
                revealButton(path: group.path)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                shareBar
                    .padding(.horizontal, 10)
                    .padding(.bottom, 3)
            }
            .onTapGesture(perform: onToggle)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider().padding(.leading, 52)
                        }
                        VStack(spacing: 0) {
                            WorkspaceItemRow(
                                item: item,
                                group: group,
                                projection: projection,
                                pendingSynchronizationIDs: pendingSynchronizationIDs,
                                selectedIDs: $selectedIDs,
                                onSelectionInteraction: onSelectionInteraction,
                                showsDisclosure: !item.worktrees.isEmpty,
                                isDisclosed: expandedItemIDs.contains(item.id) || isSearching,
                                onToggleDisclosure: { onToggleItem(item.id) }
                            )
                            if expandedItemIDs.contains(item.id) || isSearching {
                                ForEach(Array(item.worktrees.enumerated()), id: \.element.id) { wtIndex, worktree in
                                    Divider().padding(.leading, 52)
                                    WorkspaceItemRow(
                                        item: worktree,
                                        group: group,
                                        projection: projection,
                                        pendingSynchronizationIDs: pendingSynchronizationIDs,
                                        selectedIDs: $selectedIDs,
                                        onSelectionInteraction: onSelectionInteraction,
                                        showsDisclosure: false,
                                        isDisclosed: false,
                                        onToggleDisclosure: {}
                                    )
                                }
                            }
                        }
                    }
                }
                .background(Color.primary.opacity(0.016))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var countSummary: some View {
        let hasWorktrees = group.worktreeCount > 0
        return Text(hasWorktrees
            ? L10n.format("%d 个仓库 · %d 个 Worktree", group.repositoryCount, group.worktreeCount)
            : L10n.format("%d 个仓库", group.repositoryCount))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var aggregateCheckbox: some View {
        let requestIDs = groupRequestIDs
        if requestIDs.isEmpty {
            Color.clear
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        } else if requestIDs.isSubset(of: pendingSynchronizationIDs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
                .frame(width: 14, height: 14)
                .help(L10n.text("已清理，等待同步确认"))
                .accessibilityLabel(L10n.text("已清理，等待同步确认"))
        } else {
            let selectedCount = requestIDs.intersection(selectedIDs).count
            Button {
                onSelectionInteraction()
                if selectedCount == requestIDs.count {
                    selectedIDs.subtract(requestIDs)
                } else {
                    selectedIDs.formUnion(requestIDs)
                }
            } label: {
                Image(systemName: WorkspaceDisplay.selectionSymbol(
                    selectedCount: selectedCount,
                    totalCount: requestIDs.count
                ))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selectedCount == 0 ? Color.secondary : Color.accentColor)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("选择此目录中的所有可清理资源"))
            .accessibilityLabel(L10n.text("选择此目录中的所有可清理资源"))
        }
    }

    private var groupRequestIDs: Set<String> {
        var ids = Set<String>()
        func collect(_ item: WorkspaceRepositoryItem) {
            if projection.requestsByID[item.node.id] != nil {
                ids.insert(item.node.id)
            }
            for worktree in item.worktrees { collect(worktree) }
        }
        for item in group.items { collect(item) }
        return ids
    }

    private var shareBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: max(2, proxy.size.width * WorkspaceDisplay.share(group.allocatedBytes, of: totalBytes)))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private func revealButton(path: String) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("在 Finder 中显示"))
        .accessibilityLabel(L10n.text("在 Finder 中显示"))
    }
}

// MARK: - Item row

private struct WorkspaceItemRow: View {
    let item: WorkspaceRepositoryItem
    let group: WorkspaceRepositoryGroup
    let projection: StorageResourceTreeIndex
    let pendingSynchronizationIDs: Set<String>
    @Binding var selectedIDs: Set<String>
    let onSelectionInteraction: () -> Void
    let showsDisclosure: Bool
    let isDisclosed: Bool
    let onToggleDisclosure: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isPending = pendingSynchronizationIDs.contains(item.node.id)
        let isSelectable = projection.requestsByID[item.node.id] != nil
        return HStack(spacing: 7) {
            Color.clear
                .frame(width: item.kind == .worktree ? 30 : 12)
                .accessibilityHidden(true)

            disclosureControl

            selectionControl(isPending: isPending, isSelectable: isSelectable)

            Image(systemName: item.kind == .worktree
                ? "arrow.triangle.branch"
                : (item.kind == .repository ? "folder.badge.gearshape" : "folder"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.kind == .worktree ? Color.secondary : Color.accentColor)
                .frame(width: 18, height: 18)
                .background(
                    (item.kind == .worktree ? Color.secondary : Color.accentColor)
                        .opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .accessibilityHidden(true)

            Text(detailLine(isPending: isPending))
                .font(.caption.monospaced())
                .foregroundStyle(isPending ? Color.green : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if item.kind == .worktree {
                kindChip(L10n.text("Worktree"))
            }
            if item.kind == .repository, !item.worktrees.isEmpty {
                worktreeCountChip
            }
            if let branch = item.branch {
                branchChip(branch)
            }

            Text(AgentStorageSizeFormatter.string(item.node.allocatedBytes))
                .font(.caption.monospaced().weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(WorkspaceDisplay.shareText(item.node.allocatedBytes, of: group.allocatedBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            revealButton(path: item.path)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
    }

    private var disclosureControl: some View {
        Group {
            if showsDisclosure {
                Button(action: onToggleDisclosure) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isDisclosed ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text(isDisclosed ? "折叠此仓库的 Worktree" : "展开此仓库的 Worktree"))
                .accessibilityLabel(L10n.text(isDisclosed ? "折叠此仓库的 Worktree" : "展开此仓库的 Worktree"))
            } else {
                Color.clear
                    .frame(width: 12, height: 16)
                    .accessibilityHidden(true)
            }
        }
    }

    private var worktreeCountChip: some View {
        Text(L10n.format("含 %d 个 Worktree", item.worktrees.count))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            .help(L10n.text("展开此仓库的 Worktree"))
    }

    private func detailLine(isPending: Bool) -> String {
        if isPending {
            return L10n.text("已清理，等待同步确认")
        }
        return WorkspaceDisplay.displayPath(item.path)
    }

    @ViewBuilder
    private func selectionControl(isPending: Bool, isSelectable: Bool) -> some View {
        if isPending {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.green)
                .frame(width: 14, height: 14)
                .help(L10n.text("已清理，等待同步确认"))
                .accessibilityLabel(L10n.text("已清理，等待同步确认"))
        } else if isSelectable {
            let isSelected = selectedIDs.contains(item.node.id)
            Button {
                onSelectionInteraction()
                if isSelected {
                    selectedIDs.remove(item.node.id)
                } else {
                    selectedIDs.insert(item.node.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(WorkspaceDisplay.cleanupHelp(for: item.node))
            .accessibilityLabel(WorkspaceDisplay.cleanupHelp(for: item.node))
        } else {
            Image(systemName: item.node.isProtected ? "lock.fill" : "minus")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
                .help(item.node.isProtected
                    ? L10n.text("此资源受保护或必须通过官方工具管理")
                    : L10n.text("此资源不提供直接清理"))
        }
    }

    private func branchChip(_ branch: String) -> some View {
        Label(branch, systemImage: "git.branch")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .frame(maxWidth: 110)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
            .accessibilityLabel(L10n.format("分支 %@", branch))
    }

    private func kindChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 14)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
            }
    }

    private func revealButton(path: String) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("在 Finder 中显示"))
        .accessibilityLabel(L10n.text("在 Finder 中显示"))
    }
}
