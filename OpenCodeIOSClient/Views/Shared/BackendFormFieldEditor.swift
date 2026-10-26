import SwiftUI

struct BackendFormFieldEditor: View {
    let field: BackendFormField
    var customDraft: Binding<String>? = nil
    @Binding var value: OpenCodeJSONValue?
    var usesQuestionStyle = false
    var onSelectAnswer: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usesQuestionStyle ? field.raw["description"]?.v2ConfigurationString ?? field.title : field.title)
                .font(.headline)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !usesQuestionStyle, let description = field.raw["description"]?.v2ConfigurationString {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if field.type == "external" {
                if let url = field.browserURL {
                    Link("Open Browser", destination: url)
                    Toggle("I completed this step", isOn: Binding(
                        get: { value == .bool(true) }, set: { value = $0 ? .bool(true) : nil }
                    ))
                } else {
                    Text("This link cannot be opened safely. You can cancel the request.")
                        .foregroundStyle(.secondary)
                }
            } else if field.type == "boolean" {
                Picker(field.title, selection: $value) {
                    Text("Not Set").tag(Optional<OpenCodeJSONValue>.none)
                    Text("Yes").tag(Optional(OpenCodeJSONValue.bool(true)))
                    Text("No").tag(Optional(OpenCodeJSONValue.bool(false)))
                }
            } else if field.type == "multiselect" || (field.type == "string" && field.raw["options"] != nil) {
                BackendFormOptionsEditor(field: field, value: $value,
                    usesQuestionStyle: usesQuestionStyle, onSelectAnswer: onSelectAnswer)
                if field.allowsCustom {
                    if field.type == "multiselect" {
                        BackendFormCustomSelectionsEditor(value: $value, options: field.options,
                            customDraft: customDraft)
                    } else {
                        BackendFormTextEditor(field: field, value: $value, usesQuestionStyle: usesQuestionStyle,
                            customDraft: customDraft)
                    }
                }
            } else {
                BackendFormTextEditor(field: field, value: $value, usesQuestionStyle: usesQuestionStyle)
            }
            if !field.required {
                Button("Not Set") {
                    value = nil
                    if field.type == "multiselect" { customDraft?.wrappedValue = "" }
                }
                .disabled(value == nil && (field.type != "multiselect" || (customDraft?.wrappedValue ?? "").isEmpty))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form.field.\(field.id)")
    }
}

private struct BackendFormTextEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?
    var usesQuestionStyle = false
    var customDraft: Binding<String>? = nil

    var body: some View {
        if usesQuestionStyle && field.type == "string", let customDraft {
            QuestionCustomAnswerEditor(text: Binding(
                get: {
                    if let value, !field.options.contains(where: { $0["value"]?.v2FormEquals(value) == true }) {
                        return value.stringValue ?? customDraft.wrappedValue
                    }
                    return customDraft.wrappedValue
                },
                set: { text in
                    customDraft.wrappedValue = text
                    value = .string(text)
                }
            ), isActive: value != nil && value != .null && !field.options.contains { $0["value"]?.v2FormEquals(value ?? .null) == true },
                onUseAnswer: { value = .string(customDraft.wrappedValue) })
        } else {
        TextField(field.raw["placeholder"]?.v2ConfigurationString ?? field.title, text: Binding(
            get: {
                if usesQuestionStyle && field.options.contains(where: { $0["value"]?.v2FormEquals(value ?? .null) == true }) {
                    return ""
                }
                return value?.stringValue ?? ""
            },
            set: { text in value = text.isEmpty && field.type != "string" ? nil : .string(text) }
        ), axis: field.type == "string" ? .vertical : .horizontal)
        .lineLimit(1...4)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, usesQuestionStyle ? 14 : 0)
        .padding(.vertical, usesQuestionStyle ? 12 : 0)
        .background {
            if usesQuestionStyle {
                Color.clear.opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        #if os(iOS)
        .keyboardType(field.type == "number" || field.type == "integer" ? .numbersAndPunctuation : .default)
        #endif
        }
    }
}

private struct BackendFormOptionsEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?
    let usesQuestionStyle: Bool
    let onSelectAnswer: () -> Void

    var body: some View {
        ForEach(field.options, id: \.self) { option in
            if let optionValue = option["value"], let label = option["label"]?.v2ConfigurationString {
                let selected = field.type == "multiselect"
                    ? value?.arrayValue?.contains { $0.v2FormEquals(optionValue) == true } == true
                    : value?.v2FormEquals(optionValue) == true
                let select: () -> Void = {
                    if field.type == "multiselect" {
                        var selections = value?.arrayValue ?? []
                        selections.removeAll { $0.v2FormEquals(optionValue) == true }
                        if !selected { selections.append(optionValue) }
                        value = .array(selections)
                    } else {
                        value = selected ? nil : optionValue
                        if !selected { onSelectAnswer() }
                    }
                }
                if usesQuestionStyle {
                    QuestionOptionButton(title: label,
                        detail: option["description"]?.v2ConfigurationString
                            ?? (field.options.filter { $0["label"]?.v2ConfigurationString == label }.count > 1
                                ? optionValue.v2ConfigurationString ?? "" : ""),
                        isSelected: selected, allowsMultipleSelection: field.type == "multiselect",
                        action: select)
                        .accessibilityIdentifier("form.option.\(field.id).\(optionValue.v2ConfigurationString ?? "")")
                } else {
                    Button(action: select) {
                        HStack(alignment: .top) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(label)
                                if let description = option["description"]?.v2ConfigurationString {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                } else if field.options.filter({ $0["label"]?.v2ConfigurationString == label }).count > 1 {
                                    Text(optionValue.v2ConfigurationString ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

private struct BackendFormCustomSelectionsEditor: View {
    @Binding var value: OpenCodeJSONValue?
    let options: [[String: OpenCodeJSONValue]]
    var customDraft: Binding<String>? = nil
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach((value?.arrayValue ?? []).filter { candidate in
                !options.contains { $0["value"]?.v2FormEquals(candidate) == true }
            }, id: \.self) { selection in
                HStack {
                    Text(selection.v2ConfigurationString ?? "")
                    Spacer()
                    Button("Remove") {
                        value = .array((value?.arrayValue ?? []).filter { $0.v2FormEquals(selection) != true })
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                QuestionCustomAnswerEditor(text: customDraft ?? $text)
                if customDraft == nil {
                    Button("Add", action: addSelection)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addSelection() {
        let answer = customDraft?.wrappedValue ?? text
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var selections = value?.arrayValue ?? []
        let next = OpenCodeJSONValue.string(answer)
        if !selections.contains(where: { $0.v2FormEquals(next) == true }) { selections.append(next) }
        value = .array(selections)
        text = ""
        customDraft?.wrappedValue = ""
    }
}
