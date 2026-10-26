import SwiftUI

extension EnvironmentValues {
    @Entry var questionIsExpanded = false
}

/// Both protocol adapters share the same presentation; answers remain in their owner.
struct QuestionPresentation<Content: View>: View {
    let id: String
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                Button("Expand Questions", systemImage: "arrow.up.left.and.arrow.down.right") {
                    isExpanded = true
                }
                .font(.subheadline)
                .accessibilityIdentifier("question.expand.\(id)")
            }
            .padding(.horizontal, 24)
            content()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isExpanded) {
            QuestionExpandedPresentation(content: content)
        }
        #else
        .sheet(isPresented: $isExpanded) {
            QuestionExpandedPresentation(content: content)
                .frame(minWidth: 560, minHeight: 600)
        }
        #endif
    }
}

private struct QuestionExpandedPresentation<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                .environment(\.questionIsExpanded, true)
                .frame(maxWidth: 760, maxHeight: .infinity)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .navigationTitle("Questions")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("question.close")
                    }
                }
        }
    }
}

struct QuestionPageContent<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.questionIsExpanded) private var isExpanded

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: isExpanded ? .infinity : 280)
        .fixedSize(horizontal: false, vertical: !isExpanded)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A retained draft is distinct from the currently selected answer.
struct QuestionCustomAnswerEditor: View {
    @Binding var text: String
    var isActive = true
    var onUseAnswer: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type your answer", text: $text, axis: .vertical)
                .lineLimit(3...10)
                .accessibilityIdentifier("question.customAnswer")
            if !isActive && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Use Custom Answer", action: onUseAnswer)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
