import Foundation
import Observation

@MainActor
@Observable
final class SessionFormStore {
    enum Phase: Equatable {
        case ready, submitting, cancelling, checking, uncertain, unavailable
        var isBusy: Bool { self == .submitting || self == .cancelling || self == .checking }
    }

    struct EditingState: Equatable {
        var draft: BackendFormDraft = [:]
        var customAnswerDrafts: [String: String] = [:]
        var phase: Phase = .ready
        var errorMessage: String? = nil
        var operationID: UUID? = nil
        var operationConnectionID: UUID? = nil
        var operationReference: BackendFormReference? = nil
    }

    private var canonical: SessionFormStore?
    private var storedForms: [BackendFormKey: BackendForm] = [:]
    private var editedForms: [BackendFormKey: BackendForm] = [:]
    private(set) var forms: [BackendFormKey: BackendForm] {
        get { canonical?.forms ?? storedForms }
        set { storedForms = newValue }
    }
    private(set) var editing: [BackendFormKey: EditingState] = [:]
    private var storedGeneration = UUID()
    private(set) var generation: UUID {
        get { canonical?.generation ?? storedGeneration }
        set { storedGeneration = newValue }
    }
    private(set) var revision: UInt = 0
    @ObservationIgnored private var terminalKeys: Set<BackendFormKey> = []
    @ObservationIgnored var onCanonicalChange: @MainActor () -> Void = {}

    init(canonical: SessionFormStore? = nil) { self.canonical = canonical }

    func rebind(to canonical: SessionFormStore) {
        self.canonical = canonical
    }

    /// Moving is not settling: retaining tombstones in the old owner would hide forms on a return move.
    func transferSession(_ sessionID: String, to target: SessionFormStore) {
        guard target !== self else { return }
        onCanonicalChange()
        target.onCanonicalChange()
        revision &+= 1
        target.revision &+= 1
        for (key, form) in forms where key.sessionID == sessionID {
            target.storedForms[key] = form
            if var state = editing[key] {
                if state.phase.isBusy { state.phase = .uncertain }
                state.operationID = nil
                state.operationConnectionID = nil
                state.operationReference = nil
                target.editing[key] = state
            }
            storedForms[key] = nil
            editing[key] = nil
        }
        let settled = terminalKeys.filter { $0.sessionID == sessionID }
        target.terminalKeys.formUnion(settled)
        terminalKeys.subtract(settled)
    }

    func reset() {
        onCanonicalChange()
        generation = UUID()
        revision &+= 1
        forms = [:]
        editing = [:]
        editedForms = [:]
        terminalKeys = []
    }

    func upsert(_ form: BackendForm) {
        guard !terminalKeys.contains(form.key) else { return }
        onCanonicalChange()
        revision &+= 1
        if let previous = forms[form.key], previous != form { editing[form.key] = nil }
        forms[form.key] = form
    }

    @discardableResult
    func replacePendingForms(_ pending: [BackendForm], sessionID: String, ifUnchangedSince expected: UInt? = nil) -> Bool {
        guard expected == nil || expected == revision else { return false }
        let scoped = pending.filter { $0.sessionID == sessionID }
        let keys = Set(scoped.map(\.key))
        for key in Array(forms.keys) where key.sessionID == sessionID && !keys.contains(key) {
            settle(key)
        }
        for form in scoped { upsert(form) }
        return true
    }

    /// A terminal event invalidates operations before HTTP completion can update the editor.
    func settle(_ key: BackendFormKey) {
        if let canonical { canonical.settle(key); editing[key] = nil; editedForms[key] = nil; return }
        onCanonicalChange()
        revision &+= 1
        terminalKeys.insert(key)
        forms[key] = nil
        editing[key] = nil
    }

    func removeSession(_ sessionID: String) {
        for key in Array(forms.keys) where key.sessionID == sessionID { settle(key) }
    }

    func state(for key: BackendFormKey) -> EditingState {
        guard let canonical else { return editing[key] ?? .init() }
        var state = canonical.state(for: key)
        let local = editedForms[key] == canonical.forms[key] ? editing[key] : nil
        state.draft = local?.draft ?? [:]
        state.customAnswerDrafts = local?.customAnswerDrafts ?? [:]
        state.errorMessage = local?.errorMessage
        return state
    }

    func setValue(_ value: OpenCodeJSONValue?, fieldID: String, for key: BackendFormKey) {
        guard let form = forms[key], let field = form.fields.first(where: { $0.id == fieldID }),
              !state(for: key).phase.isBusy, state(for: key).phase != .unavailable else { return }
        var state = state(for: key)
        if field.type == "string", field.allowsCustom, !field.options.isEmpty {
            // Preserve a custom default or restored draft before a predefined choice replaces it.
            let previous = state.draft[fieldID] ?? field.raw["default"]
            if let previous, case .string(let text) = previous,
               !field.options.contains(where: { $0["value"]?.v2FormEquals(previous) == true }) {
                state.customAnswerDrafts[fieldID] = text
            }
            if let value, case .string(let text) = value,
               !field.options.contains(where: { $0["value"]?.v2FormEquals(value) == true }) {
                state.customAnswerDrafts[fieldID] = text
            }
        }
        state.draft[fieldID] = value ?? .null
        editedForms[key] = form
        if state.phase == .ready { state.errorMessage = nil }
        editing[key] = state
    }

    func canSubmit(_ form: BackendForm) -> Bool {
        (try? form.contract.answer(values: answerDraft(for: form))) != nil
    }

    /// Pending custom multiselect text is an answer, without an extra commit action.
    /// Keep it separate while editing so clearing it cannot remove a selected option.
    func answerDraft(for form: BackendForm) -> BackendFormDraft {
        let state = state(for: form.key)
        var draft = state.draft
        for field in form.fields where field.type == "multiselect" && field.allowsCustom {
            guard let text = state.customAnswerDrafts[field.id],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var selections = (draft[field.id] ?? field.raw["default"])?.arrayValue ?? []
            let custom = OpenCodeJSONValue.string(text)
            if !selections.contains(where: { $0.v2FormEquals(custom) == true }) {
                selections.append(custom)
            }
            draft[field.id] = .array(selections)
        }
        return draft
    }

    func setCustomAnswerDraft(_ text: String, fieldID: String, for key: BackendFormKey) {
        guard let form = forms[key], form.fields.contains(where: { $0.id == fieldID }),
              !state(for: key).phase.isBusy, state(for: key).phase != .unavailable else { return }
        var state = state(for: key)
        state.customAnswerDrafts[fieldID] = text
        if state.phase == .ready { state.errorMessage = nil }
        editedForms[key] = form
        editing[key] = state
    }

    func begin(_ phase: Phase, reference: BackendFormReference, connectionID: UUID) -> UUID? {
        if let canonical { return canonical.begin(phase, reference: reference, connectionID: connectionID) }
        let key = reference.key
        guard forms[key] != nil else { return nil }
        var state = state(for: key)
        guard !state.phase.isBusy,
              phase == .checking || (state.phase != .uncertain && state.phase != .unavailable) else { return nil }
        let token = UUID()
        state.operationID = token
        state.operationConnectionID = connectionID
        state.operationReference = reference
        state.phase = phase
        state.errorMessage = nil
        editing[key] = state
        return token
    }

    func owns(_ token: UUID, reference: BackendFormReference, connectionID: UUID, generation: UUID) -> Bool {
        if let canonical { return canonical.owns(token, reference: reference, connectionID: connectionID, generation: generation) }
        let key = reference.key
        return self.generation == generation && forms[key] != nil && editing[key]?.operationID == token
            && editing[key]?.operationConnectionID == connectionID && editing[key]?.operationReference == reference
    }

    func finish(_ token: UUID, key: BackendFormKey, phase: Phase, message: String? = nil) {
        if let canonical {
            guard canonical.editing[key]?.operationID == token else { return }
            canonical.finish(token, key: key, phase: phase)
            if let message { showValidationError(message, key: key) }
            return
        }
        guard forms[key] != nil, var state = editing[key], state.operationID == token else { return }
        state.phase = phase
        state.errorMessage = message
        state.operationID = nil
        state.operationConnectionID = nil
        state.operationReference = nil
        editing[key] = state
    }

    func showValidationError(_ message: String, key: BackendFormKey) {
        guard forms[key] != nil, !state(for: key).phase.isBusy else { return }
        var state = state(for: key)
        editedForms[key] = forms[key]
        state.errorMessage = message
        editing[key] = state
    }
}
