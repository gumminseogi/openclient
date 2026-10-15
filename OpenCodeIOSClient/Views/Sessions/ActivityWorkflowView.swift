import SwiftUI

struct ActivityWorkflowDisplayMenu<ProjectFilter: View>: View {
    @ObservedObject var facade: ActivityFacade
    @Binding var isCreatingStatus: Bool
    let projectFilter: ProjectFilter

    var body: some View {
        Menu {
            projectFilter
            Divider()
            Picker("Group By", selection: Binding(
                get: { facade.workflow.layout != .recent },
                set: { facade.workflow.setLayout($0 ? .list : .recent) }
            )) {
                Text("Recent").tag(false)
                Text("Status").tag(true)
            }
            if facade.workflow.layout != .recent {
                Picker("Layout", selection: Binding(
                    get: { facade.workflow.layout }, set: { facade.workflow.setLayout($0) }
                )) {
                    Label("List", systemImage: "list.bullet").tag(ActivityWorkflowLayout.list)
                    Label("Board", systemImage: "rectangle.split.3x1").tag(ActivityWorkflowLayout.board)
                }
                Toggle("Show Archived", isOn: Binding(
                    get: { facade.workflow.showsArchived }, set: { facade.workflow.setShowsArchived($0) }
                ))
            }
            Button("New Status", systemImage: "plus.circle") { isCreatingStatus = true }
        } label: {
            Image(systemName: facade.workflow.layout == .board ? "rectangle.split.3x1" : "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Activity Display")
        .accessibilityIdentifier("activity.display")
    }
}

struct ActivityWorkflowStatusMenu: View {
    @ObservedObject var facade: ActivityFacade
    let row: ActivityFacade.RowSnapshot

    var body: some View {
        Menu {
            ForEach(facade.workflowStatuses) { status in
                Button {
                    Task { await facade.setWorkflowStatus(status, for: row) }
                } label: {
                    Label { Text(status.title) } icon: {
                        ActivityWorkflowAppearance.symbolImage(facade.workflowStatus(for: row).id == status.id ? "checkmark" : status.symbol)
                    }
                }
                .accessibilityIdentifier("activity.status.\(status.id)")
            }
        } label: {
            Label("Status", systemImage: facade.workflowStatus(for: row).symbol)
        }
        .disabled(facade.snapshot.isReadOnly || facade.isManagingWorkflowStatus || facade.updatingWorkflowSessionIDs.contains(row.recent.session.id))
    }
}

struct ActivityWorkflowContent: View {
    @ObservedObject var facade: ActivityFacade
    let excludedProjectIDs: Set<String>
    let searchQuery: String
    let onSessionChosen: () -> Void
    @State private var editingStatus: ActivityWorkflowStatus?
    @State private var deletingStatus: ActivityWorkflowStatus?

    var body: some View {
        let sections = facade.workflowSections(excluding: excludedProjectIDs, search: searchQuery)
        Group {
            if facade.snapshot.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if facade.workflow.layout == .board {
                GeometryReader { geometry in
                    let columnWidth = min(360, max(220, geometry.size.width - 96))
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(sections) { section in
                                ActivityWorkflowColumn(facade: facade, section: section, onSessionChosen: onSessionChosen,
                                    onEdit: { editingStatus = $0 }, onDelete: { deletingStatus = $0 })
                                    .frame(width: columnWidth)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollTargetBehavior(ActivityWorkflowBoardScrollTarget(columnWidth: columnWidth, columnCount: sections.count))
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            } else {
                ActivityWorkflowList(facade: facade, sections: sections, onSessionChosen: onSessionChosen,
                    onEdit: { editingStatus = $0 }, onDelete: { deletingStatus = $0 })
            }
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .accessibilityIdentifier(facade.workflow.layout == .board ? "activity.board" : "activity.statusList")
        .sheet(item: $editingStatus) { status in
            ActivityEditStatusSheet(facade: facade, status: status)
        }
        .sheet(item: $deletingStatus) { status in
            ActivityDeleteStatusSheet(facade: facade, status: status)
        }
    }
}

private struct ActivityWorkflowBoardScrollTarget: ScrollTargetBehavior {
    let columnWidth: CGFloat
    let columnCount: Int

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard columnCount > 0 else { return }
        let step = columnWidth + 16
        let viewport = context.containerSize.width
        let end = max(0, 32 + CGFloat(columnCount) * columnWidth + CGFloat(columnCount - 1) * 16 - viewport)
        // Explicit offsets avoid view-aligned anchors reinterpreting the content
        // margins on subsequent gestures. End columns use the exact scroll limits.
        let offsets = Array(Set((0..<columnCount).map { index in
            min(end, max(0, 16 + CGFloat(index) * step + columnWidth / 2 - viewport / 2))
        })).sorted()
        let current = offsets.indices.min { abs(offsets[$0] - context.originalTarget.rect.minX) < abs(offsets[$1] - context.originalTarget.rect.minX) } ?? 0
        let proposed = offsets.indices.min { abs(offsets[$0] - target.rect.minX) < abs(offsets[$1] - target.rect.minX) } ?? current
        let next = min(current + 1, max(current - 1, proposed))
        target.rect.origin.x = offsets[next]
        target.rect.size.width = viewport
        target.anchor = .topLeading
    }
}

private struct ActivityWorkflowList: View {
    @ObservedObject var facade: ActivityFacade
    let sections: [ActivityFacade.WorkflowSection]
    let onSessionChosen: () -> Void
    let onEdit: (ActivityWorkflowStatus) -> Void
    let onDelete: (ActivityWorkflowStatus) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var collapsedStatusIDs: Set<String> { facade.workflow.collapsedStatusIDs }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(sections) { section in
                    Section {
                        if !collapsedStatusIDs.contains(section.id) {
                            if section.rows.isEmpty {
                                Text("No Sessions")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 16)
                                    .modifier(ActivityWorkflowListDropTarget(facade: facade, status: section.status))
                            }
                            ForEach(section.rows) { row in
                                ActivityWorkflowCard(facade: facade, row: row,
                                    presentation: section.status.id == ActivityWorkflowStatus.archived.id ? .summary : .fullContext,
                                    onSessionChosen: onSessionChosen)
                                    .modifier(ActivityWorkflowListDropTarget(facade: facade, status: section.status))
                                    .id(ActivityWorkflowCardIdentity(sessionID: row.id, statusID: section.id))
                                    .transition(.opacity)
                            }
                        }
                    } header: {
                        ActivityWorkflowListHeader(
                            status: section.status,
                            count: section.rows.count,
                            isExpanded: !collapsedStatusIDs.contains(section.id)
                        ) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                                facade.workflow.setCollapsed(!collapsedStatusIDs.contains(section.id), for: section.id)
                            }
                        }
                        .modifier(ActivityWorkflowListDropTarget(facade: facade, status: section.status) {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                                facade.workflow.setCollapsed(false, for: section.id)
                            }
                        })
                        .contextMenu {
                            ActivityWorkflowStatusActions(facade: facade, status: section.status, onEdit: onEdit, onDelete: onDelete)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .refreshable { await facade.prepareForPresentation(force: true) }
    }
}

private struct ActivityWorkflowListHeader: View {
    let status: ActivityWorkflowStatus
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                ActivityWorkflowHeading(status: status, count: count)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("activity.section.\(status.id)")
    }
}

/// Headers, empty sections, and cards are all destinations, including collapsed headers.
private struct ActivityWorkflowListDropTarget: ViewModifier {
    let facade: ActivityFacade
    let status: ActivityWorkflowStatus
    var onAccepted: () -> Void = {}
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: String.self) { tokens, _ in
                guard facade.dropWorkflowSessions(tokens, into: status) else { return false }
                onAccepted()
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

private struct ActivityWorkflowColumn: View {
    @ObservedObject var facade: ActivityFacade
    let section: ActivityFacade.WorkflowSection
    let onSessionChosen: () -> Void
    let onEdit: (ActivityWorkflowStatus) -> Void
    let onDelete: (ActivityWorkflowStatus) -> Void
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                Section {
                    if section.rows.isEmpty {
                        Text("No Sessions").foregroundStyle(.secondary).padding(24)
                    }
                    ForEach(section.rows) { row in
                        ActivityWorkflowCard(facade: facade, row: row,
                            presentation: section.status.id == ActivityWorkflowStatus.archived.id ? .summary : .fullContext,
                            onSessionChosen: onSessionChosen)
                            .id(ActivityWorkflowCardIdentity(sessionID: row.id, statusID: section.id))
                    }
                } header: {
                    ActivityWorkflowHeading(status: section.status, count: section.rows.count)
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                        .contentShape(.rect)
                        .contextMenu {
                            ActivityWorkflowStatusActions(facade: facade, status: section.status, onEdit: onEdit, onDelete: onDelete)
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollClipDisabled()
        .frame(maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 16))
        .dropDestination(for: String.self) { tokens, _ in
            facade.dropWorkflowSessions(tokens, into: section.status)
        } isTargeted: { isTargeted = $0 }
        .accessibilityIdentifier("activity.column.\(section.id)")
    }
}

private struct ActivityWorkflowHeading: View {
    let status: ActivityWorkflowStatus
    let count: Int

    var body: some View {
        HStack {
            Label {
                Text(status.title)
            } icon: {
                ActivityWorkflowAppearance.symbolImage(status.symbol).foregroundStyle(ActivityWorkflowAppearance.color(status.color))
            }
            Text(count, format: .number).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// A dragged session keeps its data identity, but changing its status changes its
/// rendered card identity. Lazy containers must discard the source card's cached
/// layout/drag representation when installing it in the destination section.
private struct ActivityWorkflowCardIdentity: Hashable {
    let sessionID: String
    let statusID: String
}

private struct ActivityWorkflowCard: View {
    private struct HydrationKey: Equatable {
        let generation: Int
        let presentation: ActivitySessionRowPresentation
    }

    @ObservedObject var facade: ActivityFacade
    let row: ActivityFacade.RowSnapshot
    let presentation: ActivitySessionRowPresentation
    let onSessionChosen: () -> Void

    var body: some View {
        Button {
            facade.prepareSelection(row)
            onSessionChosen()
            Task { await facade.open(row) }
        } label: {
            ActivitySessionRow(row: row, showsLastUserMessage: facade.snapshot.showsLastUserMessage,
                isSelected: facade.snapshot.selectedSessionID == row.recent.session.id,
                presentation: presentation)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("activity.session.\(row.recent.session.id)")
        .overlay(alignment: .bottomTrailing) {
            if facade.updatingWorkflowSessionIDs.contains(row.recent.session.id) {
                ProgressView().controlSize(.mini).padding(12)
            }
        }
        .draggable(facade.workflowDragToken(for: row))
        .contextMenu {
            ActivityWorkflowStatusMenu(facade: facade, row: row)
            if !facade.snapshot.isReadOnly {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    Task { await facade.delete(row) }
                }
            }
        }
        .task(id: HydrationKey(generation: row.hydrationGeneration, presentation: presentation)) {
            guard presentation == .fullContext else { return }
            await facade.hydrateIfNeeded(row)
        }
    }
}

struct ActivityCreateStatusSheet: View {
    @ObservedObject var store: ActivityWorkflowStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "circle"
    @State private var color = "blue"

    var body: some View {
        NavigationStack {
            Form {
                ActivityWorkflowStatusFields(name: $name, symbol: $symbol, color: $color)
            }
            .navigationTitle("New Status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if store.createStatus(name: name, symbol: symbol, color: color) != nil { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("activity.saveStatus")
                }
            }
        }
    }
}

private struct ActivityWorkflowStatusActions: View {
    @ObservedObject var facade: ActivityFacade
    let status: ActivityWorkflowStatus
    let onEdit: (ActivityWorkflowStatus) -> Void
    let onDelete: (ActivityWorkflowStatus) -> Void

    var body: some View {
        if !status.isBuiltIn, !facade.snapshot.isReadOnly {
            Button("Edit Status", systemImage: "pencil") { onEdit(status) }
                .disabled(facade.isManagingWorkflowStatus || !facade.updatingWorkflowSessionIDs.isEmpty)
                .accessibilityIdentifier("activity.editStatus.\(status.id)")
            Button("Delete Status", systemImage: "trash", role: .destructive) { onDelete(status) }
                .disabled(facade.isManagingWorkflowStatus || !facade.updatingWorkflowSessionIDs.isEmpty)
                .accessibilityIdentifier("activity.deleteStatus.\(status.id)")
        }
    }
}

private struct ActivityWorkflowStatusFields: View {
    @Binding var name: String
    @Binding var symbol: String
    @Binding var color: String

    var body: some View {
        TextField("Status Name", text: $name)
            .accessibilityIdentifier("activity.statusName")
        Picker("Icon", selection: $symbol) {
            ForEach(ActivityWorkflowStatus.symbols, id: \.self) { value in
                Label { Text(ActivityWorkflowAppearance.symbolTitle(value)) } icon: {
                    ActivityWorkflowAppearance.symbolImage(value)
                }.tag(value)
            }
        }
        Picker("Color", selection: $color) {
            ForEach(ActivityWorkflowStatus.colors, id: \.self) { value in
                Text(ActivityWorkflowAppearance.colorTitle(value)).tag(value)
            }
        }
        Section {
            Label { Text(name) } icon: {
                ActivityWorkflowAppearance.symbolImage(symbol)
            }.foregroundStyle(ActivityWorkflowAppearance.color(color))
        } header: {
            Text("Preview")
        } footer: {
            Text("Statuses are available across all projects. Session status is saved to metadata on supported servers.")
        }
    }
}

private struct ActivityEditStatusSheet: View {
    @ObservedObject var facade: ActivityFacade
    let status: ActivityWorkflowStatus
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "circle"
    @State private var color = "blue"
    @State private var initialized = false
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                ActivityWorkflowStatusFields(name: $name, symbol: $symbol, color: $color)
                    .disabled(isSaving)
                if isSaving { ProgressView("Updating Sessions") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Edit Status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        error = nil
                        Task {
                            defer { isSaving = false }
                            do {
                                try await facade.editWorkflowStatus(status, name: name, symbol: symbol, color: color)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("activity.saveStatus")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            guard !initialized else { return }
            name = status.name
            symbol = status.symbol
            color = status.color
            initialized = true
        }
    }
}

private struct ActivityDeleteStatusSheet: View {
    @ObservedObject var facade: ActivityFacade
    let status: ActivityWorkflowStatus
    @Environment(\.dismiss) private var dismiss
    @State private var replacementID = ActivityWorkflowStatus.inProgress.id
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Label { Text(status.title) } icon: { ActivityWorkflowAppearance.symbolImage(status.symbol) }
                Section {
                    Picker("Move Sessions To", selection: $replacementID) {
                        ForEach(facade.workflowStatuses.filter { $0.id != status.id }) { replacement in
                            Label { Text(replacement.title) } icon: {
                                ActivityWorkflowAppearance.symbolImage(replacement.symbol)
                            }.tag(replacement.id)
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("activity.replacementStatus")
                } footer: {
                    Text("Sessions using this status will move to the selected status. Sessions on the connected server are updated before the status is deleted.")
                }
                if isSaving { ProgressView("Moving Sessions") }
                if let error { Text(error).foregroundStyle(.red) }
                Button("Delete Status", role: .destructive) {
                    guard let replacement = facade.workflowStatuses.first(where: { $0.id == replacementID }) else { return }
                    isSaving = true
                    error = nil
                    Task {
                        defer { isSaving = false }
                        do {
                            try await facade.deleteWorkflowStatus(status, replacement: replacement)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(isSaving || !facade.workflowStatuses.contains { $0.id == replacementID && $0.id != status.id })
                .accessibilityIdentifier("activity.confirmDeleteStatus")
            }
            .navigationTitle("Delete Status")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}

private enum ActivityWorkflowAppearance {
    static func color(_ value: String) -> Color {
        switch value {
        case "blue": .blue
        case "purple": .purple
        case "yellow": .yellow
        case "green": .green
        case "orange": .orange
        default: .gray
        }
    }

    static func colorTitle(_ value: String) -> LocalizedStringResource {
        switch value {
        case "blue": "Blue"
        case "purple": "Purple"
        case "yellow": "Yellow"
        case "green": "Green"
        case "orange": "Orange"
        default: "Gray"
        }
    }

    static func symbolTitle(_ value: String) -> LocalizedStringResource {
        switch value {
        case "circle.dashed": "Dashed Circle"
        case "circle.dotted": "Dotted Circle"
        case "circle.lefthalf.filled": "Half-Filled Circle"
        case "circle.quarter.filled": "Quarter-Filled Circle"
        case "circle.threequarters.filled": "Three-Quarter-Filled Circle"
        case "circle.inset.filled": "Inset Circle"
        case "circle.fill": "Filled Circle"
        default: "Circle"
        }
    }

    static func symbolImage(_ value: String) -> Image {
        switch value {
        case "circle.quarter.filled": Image("WorkflowQuarterCircle")
        case "circle.threequarters.filled": Image("WorkflowThreeQuarterCircle")
        default: Image(systemName: value)
        }
    }
}
