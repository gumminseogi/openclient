import SwiftUI

enum SessionCleanupMethod: Hashable {
    case age, project, review
}

struct SessionCleanupContent: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let onSelect: (SessionCleanupMethod) -> Void

    var body: some View {
        List {
            Section {
                Text("Free up your chat list. Running chats and their parent conversations are excluded.")
                    .foregroundStyle(.secondary)
                LabeledContent("Available chats", value: store.candidates.count.formatted())
            }
            CleanupStatusSection(store: store)
            CleanupFailuresSection(coordinator: coordinator, store: store)
            Section {
                Button { onSelect(.age) } label: {
                    Label("By Age", systemImage: "calendar")
                }
                .accessibilityIdentifier("cleanup.age")
                Button { onSelect(.project) } label: {
                    Label("By Project", systemImage: "folder")
                }
                .accessibilityIdentifier("cleanup.project")
                Button { onSelect(.review) } label: {
                    Label("Review Individually", systemImage: "rectangle.stack")
                }
                .accessibilityIdentifier("cleanup.review")
            }
        }
        .disabled(store.isLoading || store.isDeleting)
        .navigationTitle("Clean Up")
        .refreshable { await coordinator.load() }
        .toolbar {
            Button { Task { await coordinator.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(store.isLoading || store.isDeleting)
        }
    }
}

struct SessionCleanupSheet: View {
    let coordinator: SessionCleanupCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SessionCleanupContent(coordinator: coordinator, store: coordinator.store) { method in
                path.append(method)
            }
            .toolbar { closeToolbar }
            .navigationDestination(for: SessionCleanupMethod.self) { method in
                SessionCleanupDetail(coordinator: coordinator, method: method) { session in
                    path.append(CleanupTranscriptRoute(session: session))
                }
                .toolbar { closeToolbar }
            }
            .navigationDestination(for: CleanupTranscriptRoute.self) { route in
                CleanupTranscriptView(coordinator: coordinator, store: coordinator.store, session: route.session)
                    .toolbar { closeToolbar }
            }
        }
        .task { await coordinator.load() }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
                .accessibilityIdentifier("cleanup.done")
        }
    }
}

struct SessionCleanupDetail: View {
    let coordinator: SessionCleanupCoordinator
    let method: SessionCleanupMethod
    let onOpenTranscript: (OpenCodeSession) -> Void

    var body: some View {
        Group {
            switch method {
            case .age: CleanupBatchView(coordinator: coordinator, store: coordinator.store, mode: .age)
            case .project: CleanupBatchView(coordinator: coordinator, store: coordinator.store, mode: .project)
            case .review: CleanupReviewView(coordinator: coordinator, store: coordinator.store, onOpenTranscript: onOpenTranscript)
            }
        }
    }
}

struct CleanupTranscriptRoute: Hashable {
    let session: OpenCodeSession
}

private struct CleanupBatchView: View {
    enum Mode {
        case age, project

        var title: LocalizedStringResource {
            switch self {
            case .age: "By Age"
            case .project: "By Project"
            }
        }
    }

    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let mode: Mode

    var body: some View {
        List {
            CleanupStatusSection(store: store)
            CleanupFailuresSection(coordinator: coordinator, store: store)
            switch mode {
            case .age:
                CleanupAgeSection(coordinator: coordinator, store: store)
            case .project:
                CleanupProjectSection(coordinator: coordinator, store: store)
            }
        }
        .navigationTitle(mode.title)
        .disabled(store.isLoading || store.isDeleting)
        .refreshable { await coordinator.load() }
        .toolbar {
            Button { Task { await coordinator.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(store.isLoading || store.isDeleting)
        }
    }
}

private struct CleanupFailuresSection: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore

    var body: some View {
        if !store.failures.isEmpty {
            Section("Could Not Delete") {
                ForEach(store.candidates.filter { store.failures[$0.id] != nil }) { candidate in
                    VStack(alignment: .leading) {
                        Text(verbatim: candidate.session.displayTitle())
                        Text(verbatim: store.failures[candidate.id] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                CleanupDeleteButton(coordinator: coordinator, store: store,
                    targets: store.candidates.filter { store.failures[$0.id] != nil })
            }
        }
    }
}

private struct CleanupStatusSection: View {
    @ObservedObject var store: SessionCleanupStore

    var body: some View {
        if store.isLoading { Section { ProgressView("Loading chats…") } }
        if store.isDeleting {
            Section { ProgressView(value: Double(store.progress), total: Double(max(1, store.total))) {
                Text("Processing chats: \(store.progress) / \(store.total)")
            } }
        }
        if let error = store.error {
            Section { Text(verbatim: error).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

private struct CleanupAgeSection: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    @State private var days = 30
    @State private var customDate = Date.now

    var body: some View {
        let cutoff = days == 0 ? customDate : Calendar.current.date(byAdding: .day, value: -days, to: .now)!
        let targets = store.older(than: cutoff)
        Section {
            Picker("Inactive for", selection: $days) {
                Text("30 days").tag(30)
                Text("60 days").tag(60)
                Text("90 days").tag(90)
                Text("Custom cutoff").tag(0)
            }
            if days == 0 { DatePicker("Last active before", selection: $customDate, in: ...Date.now, displayedComponents: .date) }
            LabeledContent("Matching chats", value: targets.count.formatted())
            CleanupDeleteButton(coordinator: coordinator, store: store, targets: targets)
        } footer: { Text("Uses last activity, including child agents, rather than creation date.") }
    }
}

private struct CleanupProjectSection: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    @State private var selected = Set<String>()

    var body: some View {
        Section {
            ForEach(store.projects) { project in
                let count = store.candidates.filter { $0.session.projectID == project.id }.count
                Button {
                    if !selected.insert(project.id).inserted { selected.remove(project.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(project.id) ? "checkmark.circle.fill" : "circle")
                        Text(verbatim: store.projectName(project.id)).foregroundStyle(.primary)
                        Spacer()
                        Text(count.formatted()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(project.id) ? .isSelected : [])
            }
            CleanupDeleteButton(coordinator: coordinator, store: store,
                targets: store.candidates.filter { selected.contains($0.session.projectID ?? "") })
        }
    }
}

private struct CleanupDeleteButton: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let targets: [SessionCleanupStore.Candidate]
    @State private var confirmationTargets: [SessionCleanupStore.Candidate] = []
    @State private var confirming = false

    var body: some View {
        Button(role: .destructive) {
            confirmationTargets = targets
            confirming = true
        } label: {
            if targets.count == 1 { Text("Delete 1 Chat") }
            else { Text("Delete \(targets.count) Chats") }
        }
        .disabled(targets.isEmpty || store.isLoading || store.isDeleting)
        .confirmationDialog("Delete these chats?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await coordinator.deleteCandidates(confirmationTargets) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes the selected conversations and their child agents from the server. It cannot be undone.")
        }
    }
}

private struct CleanupReviewView: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let onOpenTranscript: (OpenCodeSession) -> Void
    @State private var isAdvancing = false
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Swipe right to keep, left to queue for deletion. Nothing is deleted until you confirm.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if store.current != nil {
                    CleanupReviewDeck(coordinator: coordinator, store: store,
                        candidates: store.reviewCards, viewportWidth: viewportWidth, isAdvancing: $isAdvancing,
                        onOpenTranscript: onOpenTranscript)
                } else {
                    ContentUnavailableView("Review Complete", systemImage: "checkmark.circle",
                        description: Text("Confirm your queued deletions below, or undo your last decision."))
                }
                Button { store.undo() } label: { Label("Undo Last Swipe", systemImage: "arrow.uturn.backward") }
                    .disabled(store.decisions.isEmpty || isAdvancing)
                CleanupDeleteButton(coordinator: coordinator, store: store,
                    targets: store.candidates.filter { store.pendingIDs.contains($0.id) })
                    .buttonStyle(.bordered)
                    .disabled(isAdvancing)
                CleanupStatusSection(store: store)
            }
            .padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
        }
        .disabled(store.isDeleting)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .navigationTitle("Review Individually")
    }
}

private struct CleanupReviewDeck: View {
    private struct Flight {
        let id = UUID()
        let sessionID: String
        let delete: Bool
    }

    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let candidates: [SessionCleanupStore.Candidate]
    let viewportWidth: CGFloat
    @Binding var isAdvancing: Bool
    let onOpenTranscript: (OpenCodeSession) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var offset = CGSize.zero
    @State private var cardWidth: CGFloat = 0
    @State private var opacity = 1.0
    @State private var flight: Flight?

    var body: some View {
        let reveal = reduceMotion ? 0 : min(abs(offset.width) / max(1, cardWidth * 0.75), 1)
        VStack(spacing: 20) {
            ZStack(alignment: .top) {
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    let depth = min(2, max(0, CGFloat(index) - reveal))
                    if index == 0 {
                        CleanupReviewCard(coordinator: coordinator, store: store, candidate: candidate, onOpenTranscript: onOpenTranscript)
                            .overlay {
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(offset.width > 0 ? Color.green : Color.red,
                                        lineWidth: 2)
                                    .opacity(min(abs(offset.width) / 80, 1))
                                    .allowsHitTesting(false)
                            }
                            .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
                            .rotationEffect(.degrees(reduceMotion ? 0 : max(-18, min(18, Double(offset.width / 25)))))
                            .offset(offset)
                            .opacity(opacity)
                            .highPriorityGesture(DragGesture(minimumDistance: 25, coordinateSpace: .global)
                                .updating($isDragging) { _, active, _ in active = true }
                                .onChanged { value in
                                    guard flight == nil,
                                          abs(value.translation.width) > abs(value.translation.height) else { return }
                                    offset = CGSize(width: value.translation.width,
                                        height: reduceMotion ? 0 : value.translation.height * 0.12)
                                }
                                .onEnded { value in
                                    guard flight == nil else { return }
                                    let threshold = max(90, cardWidth * 0.24)
                                    let projected = value.predictedEndTranslation.width
                                    guard abs(value.translation.width) > abs(value.translation.height),
                                          abs(value.translation.width) > threshold || abs(projected) > threshold else {
                                        returnToStack()
                                        return
                                    }
                                    let destination = abs(projected) > threshold ? projected : value.translation.width
                                    dismissCard(delete: destination < 0, velocity: value.velocity.width)
                                })
                            .allowsHitTesting(!isAdvancing)
                            .zIndex(Double(candidates.count))
                    } else {
                        CleanupReviewCardFace(projectName: store.projectName(candidate.session.projectID),
                            candidate: candidate, transcript: store.transcripts[candidate.id])
                            .scaleEffect(1 - depth * 0.045, anchor: .top)
                            .offset(y: depth * 40)
                            .shadow(color: .black.opacity(0.08), radius: 6, y: 4)
                            .opacity(index == 3 ? reveal : 1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .zIndex(Double(candidates.count - index))
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
            // Reserve the full stack footprint even near the end of the queue.
            .padding(.bottom, 80)
            HStack(spacing: 24) {
                Button { dismissCard(delete: true) } label: { Label("Delete", systemImage: "trash") }
                    .tint(.red).accessibilityIdentifier("cleanup.swipe.delete")
                Button { dismissCard(delete: false) } label: { Label("Keep", systemImage: "checkmark") }
                    .tint(.green).accessibilityIdentifier("cleanup.swipe.keep")
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(isAdvancing)
        }
        .onChange(of: isDragging) { _, dragging in
            // Also restore the card when the system cancels a drag.
            if !dragging && flight == nil { returnToStack() }
        }
        .onChange(of: candidates.first?.id) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                flight = nil
                offset = .zero
                opacity = 1
                isAdvancing = false
            }
        }
        .onDisappear {
            flight = nil
            offset = .zero
            opacity = 1
            isAdvancing = false
        }
        .task(id: candidates.map(\.id)) {
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                await coordinator.loadTranscript(candidate.session)
            }
        }
    }

    private func returnToStack() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78)) {
            offset = .zero
        }
    }

    private func dismissCard(delete: Bool, velocity: CGFloat = 0) {
        guard flight == nil, !store.isDeleting, let candidate = candidates.first else { return }
        let distance = (max(viewportWidth, cardWidth) + cardWidth) / 2 + 160
        let targetX = delete ? -distance : distance
        let remaining = targetX - offset.width
        let speed = max(900, abs(velocity))
        let duration = reduceMotion ? 0.16 : min(0.42, max(0.2, Double(abs(remaining) / speed)))
        let pending = Flight(sessionID: candidate.id, delete: delete)
        flight = pending
        isAdvancing = true
        let animation: Animation = reduceMotion ? .easeOut(duration: duration)
            : .timingCurve(0.18, 0.7, 0.32, 1, duration: duration)
        withAnimation(animation, completionCriteria: .removed) {
            if reduceMotion { opacity = 0 }
            else { offset = CGSize(width: targetX, height: offset.height * 1.5) }
        } completion: {
            // Keep the outgoing identity mounted until the animation has finished.
            // Leaving the screen invalidates the flight rather than deciding another card.
            guard flight?.id == pending.id else { return }
            isAdvancing = false
            if store.current?.id == pending.sessionID { store.decide(delete: pending.delete) }
        }
    }
}

private struct CleanupReviewCard: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let candidate: SessionCleanupStore.Candidate
    let onOpenTranscript: (OpenCodeSession) -> Void

    var body: some View {
        Button {
            onOpenTranscript(candidate.session)
        } label: {
            CleanupReviewCardFace(projectName: store.projectName(candidate.session.projectID),
                candidate: candidate, transcript: store.transcripts[candidate.id])
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cleanup.card.\(candidate.id)")
        .accessibilityHint("Open the read-only conversation")
    }
}

private struct CleanupReviewCardFace: View {
    let projectName: String
    let candidate: SessionCleanupStore.Candidate
    let transcript: SessionCleanupStore.Transcript?
    @ScaledMetric(relativeTo: .body) private var contentHeight: CGFloat = 352

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: projectName)
                .font(.caption).foregroundStyle(.secondary)
            Text(verbatim: candidate.session.displayTitle()).font(.title2.bold()).lineLimit(2)
            if let date = candidate.lastActivity {
                Text(date, format: .dateTime.month().day().year()).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if transcript?.isLoading == true { ProgressView() }
            if let error = transcript?.error { Text(verbatim: error).foregroundStyle(.red).lineLimit(3) }
            if let message = transcript?.messages.last(where: { $0.parts.contains { $0.type == "text" && $0.text?.isEmpty == false } }) {
                Text(verbatim: message.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"))
                    .lineLimit(10).font(.body)
            } else if transcript?.loaded == true { Text("No messages") }
            Spacer(minLength: 0)
            Label("Tap to Read Chat", systemImage: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: contentHeight, alignment: .topLeading)
        .clipped()
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
}

struct CleanupTranscriptView: View {
    let coordinator: SessionCleanupCoordinator
    @ObservedObject var store: SessionCleanupStore
    let session: OpenCodeSession

    var body: some View {
        let transcript = store.transcripts[session.id] ?? .init()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if transcript.olderCursor != nil {
                    Button("Load Earlier Messages") { Task { await coordinator.loadTranscript(session, older: true) } }
                        .disabled(transcript.isLoading)
                }
                if transcript.isLoading { ProgressView() }
                if let error = transcript.error {
                    Text(verbatim: error).foregroundStyle(.red)
                    Button("Retry") { Task { await coordinator.loadTranscript(session, older: transcript.loaded) } }
                }
                if transcript.loaded && transcript.messages.isEmpty { Text("No messages") }
                ForEach(transcript.messages) { message in
                    CleanupTranscriptMessage(message: message)
                }
            }
            .padding().frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .navigationTitle(session.displayTitle())
        .accessibilityIdentifier("cleanup.transcript")
        .task { await coordinator.loadTranscript(session) }
    }
}

private struct CleanupTranscriptMessage: View {
    let message: OpenCodeMessageEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.info.role == "user" { Text("You").font(.caption.bold()) }
            else { Text("Assistant").font(.caption.bold()) }
            ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                if part.type == "reasoning", let text = part.text {
                    DisclosureGroup("Reasoning") { MarkdownMessageText(text: text, isUser: false, style: .reasoning) }
                } else if OpenCodeToolActivityPolicy.isToolCall(part) {
                    DisclosureGroup {
                        if let input = part.state?.input {
                            Text(verbatim: String(describing: input)).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let output = part.state?.output { Text(verbatim: output).font(.caption.monospaced()).textSelection(.enabled) }
                        if let error = part.state?.error { Text(verbatim: error).foregroundStyle(.red) }
                    } label: { Label(part.tool ?? part.type, systemImage: "wrench.and.screwdriver") }
                } else if let text = part.text, !text.isEmpty {
                    MarkdownMessageText(text: text, isUser: message.info.role == "user", style: .standard)
                } else if part.type == "file" {
                    Label(part.filename ?? part.mime ?? part.type, systemImage: "paperclip")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.quaternary.opacity(message.info.role == "user" ? 0.7 : 0.2), in: RoundedRectangle(cornerRadius: 16))
    }
}
