import SwiftUI

/// A bounded editor in the composer area. Permissions retain priority in ChatView.
struct SessionFormPanel: View {
    let forms: [BackendForm]
    let store: SessionFormStore
    let contextID: String
    let allowsActions: Bool
    var usesQuestionStyle = false
    let submit: (BackendForm) async -> Void
    let cancel: (BackendForm) async -> Void
    let refresh: (BackendForm) async -> Void

    var body: some View {
        if let form = forms.first {
            SessionFormCard(form: form, pendingCount: forms.count, store: store, contextID: contextID,
                allowsActions: allowsActions, usesQuestionStyle: usesQuestionStyle, submit: { await submit(form) },
                cancel: { await cancel(form) }, refresh: { await refresh(form) })
                .id(form.key)
        }
    }
}

private struct SessionFormCard: View {
    let form: BackendForm
    let pendingCount: Int
    let store: SessionFormStore
    let contextID: String
    let allowsActions: Bool
    let usesQuestionStyle: Bool
    let submit: () async -> Void
    let cancel: () async -> Void
    let refresh: () async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedFieldID: String?

    var body: some View {
        QuestionPresentation(id: form.id) {
            SessionFormCardContent(form: form, pendingCount: pendingCount, store: store,
                allowsActions: allowsActions, usesQuestionStyle: usesQuestionStyle,
                selectedFieldID: $selectedFieldID, submit: submit, cancel: cancel, refresh: refresh)
        }
        .task(id: contextID) { if allowsActions { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && allowsActions { Task { await refresh() } }
        }
    }
}

private struct SessionFormCardContent: View {
    let form: BackendForm
    let pendingCount: Int
    let store: SessionFormStore
    let allowsActions: Bool
    let usesQuestionStyle: Bool
    @Binding var selectedFieldID: String?
    let submit: () async -> Void
    let cancel: () async -> Void
    let refresh: () async -> Void

    var body: some View {
        let state = store.state(for: form.key)
        let fields = form.contract.activeFields(values: store.answerDraft(for: form))
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(form.title).font(.headline)
                    Spacer()
                    if state.phase.isBusy { ProgressView() }
                }
                if let message = form.metadata?["message"]?.literalStringValue {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
                if pendingCount > 1 {
                    Text("\(pendingCount) pending forms").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, usesQuestionStyle ? 24 : 0)
            if form.contract.isSupported() {
                if usesQuestionStyle {
                    SessionFormCarousel(form: form, fields: fields, store: store, selectedFieldID: $selectedFieldID)
                        .disabled(!allowsActions || state.phase.isBusy || state.phase == .unavailable)
                } else {
                    SessionFormFieldList(form: form, fields: fields, store: store)
                        .disabled(!allowsActions || state.phase.isBusy || state.phase == .unavailable)
                }
            } else {
                Text("This form contains unsupported fields. You can cancel the request.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, usesQuestionStyle ? 24 : 0)
            }
            if let error = state.errorMessage {
                Text(error).font(.subheadline).foregroundStyle(.red)
                    .accessibilityIdentifier("form.error.\(form.id)")
                    .padding(.horizontal, usesQuestionStyle ? 24 : 0)
            } else if state.phase == .uncertain {
                Text("The form status is unknown. Check status before trying again.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, usesQuestionStyle ? 24 : 0)
            }
            if !allowsActions {
                Text("Form actions are unavailable on this connection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, usesQuestionStyle ? 24 : 0)
            }
            HStack {
                Button(role: .cancel) { Task { await cancel() } } label: {
                    Text("Cancel Request")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(height: 52)
                .disabled(!allowsActions || state.phase != .ready)
                .accessibilityIdentifier("form.cancel.\(form.id)")
                if state.phase == .uncertain || state.phase == .unavailable {
                    Button("Check Status") { Task { await refresh() } }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .disabled(!allowsActions)
                        .accessibilityIdentifier("form.refresh.\(form.id)")
                } else {
                    Button { Task { await submit() } } label: {
                        Text("Submit")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .controlSize(.large)
                    .modifier(AppAccentActionModifier())
                    .opencodePrimaryGlassButton()
                    .frame(height: 52)
                    .disabled(!allowsActions || state.phase != .ready || !store.canSubmit(form))
                    .accessibilityIdentifier("form.submit.\(form.id)")
                }
            }
            .padding(8)
            .opencodeConcentricGlassSurface(minimumCornerRadius: 30, in: Capsule())
            .padding(.horizontal, usesQuestionStyle ? 16 : 0)
        }
        .padding(usesQuestionStyle ? 0 : 14)
        .background {
            if !usesQuestionStyle {
                Color.clear.opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.sessionForm.\(form.id)")
    }
}

private struct SessionFormFieldList: View {
    let form: BackendForm
    let fields: [BackendFormField]
    let store: SessionFormStore

    var body: some View {
        let draft = store.state(for: form.key).draft
        QuestionPageContent {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if field.required { Text("Required") } else { Text("Optional") }
                            if draft[field.id] == nil && field.raw["default"] != nil { Text("Default") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        BackendFormFieldEditor(field: field, customDraft: Binding(
                            get: { store.state(for: form.key).customAnswerDrafts[field.id, default: ""] },
                            set: { store.setCustomAnswerDraft($0, fieldID: field.id, for: form.key) }
                        ), value: Binding(
                            get: {
                                let value = draft[field.id] ?? field.raw["default"]
                                return value == .null ? nil : value
                            },
                            set: { store.setValue($0, fieldID: field.id, for: form.key) }
                        ))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Field keys keep page identity stable when a typed answer reveals conditional fields.
private struct SessionFormCarousel: View {
    let form: BackendForm
    let fields: [BackendFormField]
    let store: SessionFormStore
    @Binding var selectedFieldID: String?

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 12) {
                    ForEach(fields) { field in
                        QuestionPageContent {
                            SessionFormQuestionPage(field: field, index: fields.firstIndex(where: { $0.id == field.id }) ?? 0,
                                count: fields.count,
                                showsDefault: store.state(for: form.key).draft[field.id] == nil && field.raw["default"] != nil,
                                customDraft: Binding(
                                    get: { store.state(for: form.key).customAnswerDrafts[field.id, default: ""] },
                                    set: { store.setCustomAnswerDraft($0, fieldID: field.id, for: form.key) }
                                ),
                                value: Binding(
                                    get: {
                                        let value = store.state(for: form.key).draft[field.id] ?? field.raw["default"]
                                        return value == .null ? nil : value
                                    },
                                    set: { store.setValue($0, fieldID: field.id, for: form.key) }
                                ), onSelectAnswer: { advance(after: field.id) })
                        }
                        .accessibilityIdentifier("form.page.\(field.id)")
                        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .containerRelativeFrame(.horizontal)
                        .id(field.id)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $selectedFieldID)
            .animation(opencodeSelectionAnimation, value: selectedFieldID)
            .accessibilityIdentifier("form.carousel.\(form.id)")
            .onAppear {
                if let id = selectedFieldID ?? fields.first?.id {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            }

            if fields.count > 1 {
                QuestionPageIndicator(count: fields.count,
                    selectedIndex: fields.firstIndex(where: { $0.id == selectedFieldID }) ?? 0,
                    onSelect: { selectedFieldID = fields[$0].id })
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: fields.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selectedFieldID }) {
                selectedFieldID = ids.first
            }
        }
    }

    private func advance(after id: String) {
        // Read the updated draft so a newly revealed conditional question is not skipped.
        let active = form.contract.activeFields(values: store.answerDraft(for: form))
        guard let index = active.firstIndex(where: { $0.id == id }), index + 1 < active.count else { return }
        selectedFieldID = active[index + 1].id
    }
}

private struct SessionFormQuestionPage: View {
    let field: BackendFormField
    let index: Int
    let count: Int
    let showsDefault: Bool
    @Binding var customDraft: String
    @Binding var value: OpenCodeJSONValue?
    let onSelectAnswer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if field.raw["description"]?.v2ConfigurationString != nil {
                    Text(field.title)
                }
                if field.required { Text("Required") } else { Text("Optional") }
                if showsDefault { Text("Default") }
                Spacer()
                if count > 1 { Text("\(index + 1) of \(count)").monospacedDigit() }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            BackendFormFieldEditor(field: field, customDraft: $customDraft, value: $value, usesQuestionStyle: true,
                onSelectAnswer: onSelectAnswer)
        }
        .padding(.horizontal, 2)
    }
}

#if DEBUG
/// Uses the shipping panel and store without a server or provider call.
struct SessionFormVisualFixture: View {
    @State private var store = SessionFormStore()
    @State private var result = ""
    @State private var legacyAnswers: [String: Set<String>] = [:]
    @State private var legacyCustomAnswers: [String: String] = [:]

    private var isRegressionFixture: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_QUESTION_REGRESSION"] == "1" }
    private var isLegacy: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_QUESTION_LEGACY"] == "1" }
    private static let longPrompt = Array(repeating: "Explain the implementation tradeoffs, accessibility behavior, and how the selected approach will adapt between compact and expanded layouts.", count: 5).joined(separator: "\n")
    private static let regressionOptions = (1...8).map { index in
        OpenCodeQuestionOption(label: "Approach \(index)", description: "Detailed explanation of approach \(index), including compatibility, accessibility, and migration considerations across all supported devices.")
    }
    private static let legacyRequest = OpenCodeQuestionRequest(id: "visual-question", sessionID: "visual-session", questions: [
        .init(question: longPrompt, header: "Implementation choices", options: regressionOptions),
        .init(question: "Confirm the deployment target", header: "Deployment", options: [.init(label: "All devices", description: "Phone and tablet")])
    ], tool: nil)
    private var displayedForm: BackendForm {
        if ProcessInfo.processInfo.environment["OPENCLIENT_QUESTION_MULTI_REGRESSION"] == "1" {
            return BackendForm(id: "visual-question", sessionID: "visual-session", title: "Implementation choices", fields: [
                BackendFormField(raw: ["key": .string("approaches"), "type": .string("multiselect"),
                    "title": .string(Self.longPrompt), "required": .bool(true), "custom": .bool(true),
                    "options": .array(Self.regressionOptions.map { .object(["value": .string($0.label), "label": .string($0.label), "description": .string($0.description)]) })])
            ])
        }
        guard isRegressionFixture else { return Self.form }
        return BackendForm(id: "visual-question", sessionID: "visual-session", title: "Implementation choices", fields: [
            BackendFormField(raw: ["key": .string("framework"), "type": .string("string"), "title": .string(Self.longPrompt), "required": .bool(true), "custom": .bool(true),
                "options": .array(Self.regressionOptions.map { .object(["value": .string($0.label), "label": .string($0.label), "description": .string($0.description)]) })]),
            BackendFormField(raw: ["key": .string("target"), "type": .string("string"), "title": .string("Confirm the deployment target"), "required": .bool(true), "custom": .bool(true),
                "options": .array([.object(["value": .string("All devices"), "label": .string("All devices")])])])
        ])
    }

    private static let form = BackendForm(id: "visual-question", sessionID: "visual-session",
        title: "Implementation choices", fields: [
            BackendFormField(raw: ["key": .string("framework"), "type": .string("string"),
                "title": .string("Framework"), "description": .string("Which framework should we use?"), "required": .bool(true),
                "options": .array([
                    .object(["value": .string("swiftui"), "label": .string("SwiftUI"),
                        "description": .string("Native declarative interface")]),
                    .object(["value": .string("uikit"), "label": .string("UIKit"),
                        "description": .string("Traditional view controllers")])])]),
            BackendFormField(raw: ["key": .string("targets"), "type": .string("multiselect"),
                "title": .string("Which platforms should we support?"), "required": .bool(true),
                "custom": .bool(true), "options": .array([
                    .object(["value": .string("phone"), "label": .string("iPhone")]),
                    .object(["value": .string("tablet"), "label": .string("iPad")])])])
        ])

    var body: some View {
        VStack {
            Spacer()
            if result.isEmpty {
                if isLegacy {
                    QuestionPanel(requests: [Self.legacyRequest], answers: $legacyAnswers, customAnswers: $legacyCustomAnswers,
                        onDismiss: { _ in result = "cancelled" }, onSubmit: { _, answers in
                            if let data = try? JSONEncoder().encode(answers) { result = String(decoding: data, as: UTF8.self) }
                        })
                } else {
                SessionFormPanel(forms: [displayedForm], store: store, contextID: "visual-fixture",
                    allowsActions: true, usesQuestionStyle: true,
                    submit: { form in
                        if let answer = try? form.contract.answer(values: store.answerDraft(for: form)),
                           let data = try? JSONEncoder().encode(answer) {
                            result = String(decoding: data, as: UTF8.self)
                        }
                    }, cancel: { _ in result = "cancelled" }, refresh: { _ in })
                }
            } else {
                Text(verbatim: result).accessibilityIdentifier("form.fixture.result")
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { store.upsert(displayedForm) }
    }
}
#endif
