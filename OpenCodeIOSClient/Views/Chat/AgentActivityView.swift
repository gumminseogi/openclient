import SwiftUI

struct AgentActivityBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var facade: ChatFacade
    let parent: OpenCodeSession
    @Binding var isPresented: Bool

    var body: some View {
        let agents = facade.agentActivity(parentID: parent.id)
        let isRunning = agents.contains(where: { $0.status == .running })
        VStack(spacing: 0) {
            if isRunning {
                Button { isPresented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2")
                        Text("Agents").fontWeight(.semibold)
                        Spacer(minLength: 8)
                        AgentActivitySummary(agents: agents)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .opencodeGlassSurface(isInteractive: true, in: RoundedRectangle(cornerRadius: 16))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.agents.summary")
                .padding(.horizontal, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3, extraBounce: 0), value: isRunning)
    }
}

private struct AgentActivitySummary: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agents: [AgentActivitySnapshot]

    var body: some View {
        let running = agents.filter { $0.status == .running }.count
        let attention = agents.filter { $0.status == .permission || $0.status == .question }.count
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                if running > 0 {
                    Text("\(running) running")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(running)))
                        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.25), value: running)
                        .modifier(AgentActivityShimmer())
                }
                if attention == 1 { Text("1 needs attention") }
                if attention > 1 { Text("\(attention) need attention") }
                if running == 0 && attention == 0 {
                    if agents.count == 1 { Text("1 agent") } else { Text("\(agents.count) agents") }
                }
            }
            if agents.count == 1 { Text("1 agent") } else { Text("\(agents.count) agents") }
        }
        .foregroundStyle(.secondary)
    }
}

private struct AgentActivityShimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion && scenePhase == .active {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, .primary.opacity(0.5), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.6)
                    .phaseAnimator([CGFloat(-1), CGFloat(1.5)]) { highlight, phase in
                        highlight.offset(x: geometry.size.width * phase)
                    } animation: { phase in
                        .linear(duration: phase < 0 ? 0 : 1.8)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

struct AgentActivitySheet: View {
    @ObservedObject var facade: ChatFacade
    let parent: OpenCodeSession
    let imageContent: OpenClientImageContentCoordinator?
    let videoStreams: OpenClientVideoStreamCoordinator?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
    @State private var detent: PresentationDetent = .medium
    @State private var loadFailed = false
    @State private var isLoading = true

    var body: some View {
        let agents = facade.agentActivity(parentID: parent.id)
        let inProgress = agents.filter { !$0.status.isFinished }
        let completed = agents.filter { $0.status.isFinished }
        NavigationStack(path: $path) {
            List {
                if loadFailed {
                    Label("Unable to load agents", systemImage: "exclamationmark.triangle")
                }
                if !inProgress.isEmpty {
                    Section("In Progress") {
                        ForEach(inProgress) { agent in
                            AgentActivityListRow(agent: agent)
                        }
                    }
                }
                if !completed.isEmpty {
                    Section("Completed") {
                        ForEach(completed) { agent in
                            AgentActivityListRow(agent: agent)
                        }
                    }
                }
            }
            .navigationTitle("Agents")
            .overlay {
                if agents.isEmpty && !loadFailed {
                    if isLoading {
                        ProgressView()
                    } else {
                        ContentUnavailableView("No Subagents", systemImage: "person.2")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { id in
                AgentConversationDestination(facade: facade, sessionID: id, imageContent: imageContent, videoStreams: videoStreams)
            }
            .refreshable { await reload() }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: path) { _, value in if !value.isEmpty { detent = .large } }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await facade.hydrateAgentActivity(parent: parent)
            loadFailed = false
        } catch is CancellationError {
        } catch { loadFailed = true }
    }
}

private struct AgentActivityListRow: View {
    let agent: AgentActivitySnapshot

    var body: some View {
        NavigationLink(value: agent.id) {
            HStack(spacing: 12) {
                if agent.status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: agent.status.symbol)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: agent.title).font(.headline)
                    if let name = agent.agent {
                        Text(verbatim: name).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(agent.status.title).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct AgentConversationDestination: View {
    let facade: ChatFacade
    let sessionID: String
    let imageContent: OpenClientImageContentCoordinator?
    let videoStreams: OpenClientVideoStreamCoordinator?
    @State private var presentation: TaskSessionPresentation?
    @State private var failed = false

    var body: some View {
        Group {
            if let presentation {
                ChatView(chatFacade: presentation.chatFacade, browser: presentation.context.browser,
                         imageContent: imageContent, videoStreams: videoStreams, sessionID: sessionID,
                         isDedicatedWindow: true, usesSheetNavigation: true)
            } else if failed {
                ContentUnavailableView("Unable to open agent", systemImage: "exclamationmark.bubble")
            } else {
                ProgressView()
            }
        }
        .task(id: sessionID) {
            guard presentation == nil else { return }
            guard let session = await facade.sessionForPresentation(sessionID: sessionID), !Task.isCancelled,
                  let child = facade.childPresentation(for: session),
                  let result = TaskSessionPresentation(sessionID: sessionID, chatFacade: child) else {
                failed = true
                return
            }
            presentation = result
        }
        .onDisappear {
            presentation?.context.close()
            presentation = nil
        }
    }
}
