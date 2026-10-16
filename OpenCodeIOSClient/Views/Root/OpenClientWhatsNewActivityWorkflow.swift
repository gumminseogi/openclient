import SwiftUI

struct OpenClientWhatsNewActivityWorkflow: View {
    let release: OpenClientReleaseNotes
    @ObservedObject var store: ActivityWorkflowStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusLayout: ActivityWorkflowLayout = .list
    @State private var demoIsUnread = true

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            OpenClientWhatsNewHero(version: release.version, title: release.title,
                                  summary: release.summary, hero: release.hero)

            VStack(alignment: .leading, spacing: 14) {
                ActivityAnnouncementSectionHeading(title: "Your Activity, your way",
                                                   symbol: "rectangle.3.group", tint: .blue)
                Text("Follow the latest conversations, or give every chat a place in your workflow.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Picker("Group By", selection: Binding(
                    get: { store.layout != .recent },
                    set: { store.setLayout($0 ? statusLayout : .recent) }
                )) {
                    Text("Recent").tag(false)
                    Text("Status").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("announcement.activity.grouping")

                if store.layout != .recent {
                    Picker("Layout", selection: Binding(
                        get: { store.layout },
                        set: { statusLayout = $0; store.setLayout($0) }
                    )) {
                        Text("List").tag(ActivityWorkflowLayout.list)
                        Text("Board").tag(ActivityWorkflowLayout.board)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("announcement.activity.layout")
                }

                ActivityAnnouncementPreview(layout: store.layout)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: store.layout)

                Text("Your choice applies to Activity. You can change it anytime from the display menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Label("Create your own statuses with a name, color, and icon. Move chats between them with a drag or the Status menu.", systemImage: "circle.lefthalf.filled")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.05), in: .rect(cornerRadius: 16))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 14) {
                ActivityAnnouncementSectionHeading(title: "Know what’s new",
                                                   symbol: "envelope.badge", tint: .green)
                Text("Unread dots highlight new replies. Open a chat to catch up, or use Mark All as Read to clear the backlog. Read state syncs on supported servers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Try it here")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ActivityAnnouncementRow(title: "Polish the launch", detail: "The update is ready for review.", isUnread: demoIsUnread)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { demoIsUnread.toggle() }
                    } label: {
                        if demoIsUnread {
                            Label("Mark as Read", systemImage: "envelope.open")
                        } else {
                            Label("Replay Demo", systemImage: "arrow.counterclockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("announcement.activity.tryRead")
                    .accessibilityValue(demoIsUnread ? Text("Unread") : Text("Read"))
                }
                .padding(16)
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: .rect(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
                }
            }
        }
        .onAppear {
            if store.layout != .recent { statusLayout = store.layout }
        }
    }
}

private struct ActivityAnnouncementPreview: View {
    let layout: ActivityWorkflowLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview").font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: layout == .board ? "rectangle.split.3x1" : "list.bullet")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
            if layout == .board {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        previewGroup(title: "In Progress", symbol: "circle.lefthalf.filled", tint: .yellow, archived: false)
                            .frame(width: 230)
                        previewGroup(title: "Archived", symbol: "circle.fill", tint: .gray, archived: true)
                            .frame(width: 230)
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("announcement.activity.preview.board")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    previewGroup(title: layout == .recent ? "Today" : "In Progress",
                                 symbol: layout == .recent ? "clock" : "circle.lefthalf.filled",
                                 tint: layout == .recent ? .secondary : .yellow, archived: false)
                    previewGroup(title: layout == .recent ? "Yesterday" : "Archived",
                                 symbol: layout == .recent ? "clock.arrow.circlepath" : "circle.fill",
                                 tint: .gray, archived: true)
                }
                .accessibilityIdentifier(layout == .recent ? "announcement.activity.preview.recent" : "announcement.activity.preview.list")
            }
        }
        .padding(14)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func previewGroup(title: LocalizedStringResource, symbol: String, tint: Color, archived: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
                .font(.caption.weight(.semibold))
            if archived {
                ActivityAnnouncementRow(title: "Update the docs", detail: nil, isUnread: false)
            } else {
                ActivityAnnouncementRow(title: "Polish the launch", detail: "The update is ready for review.", isUnread: true)
                ActivityAnnouncementRow(title: "Plan the next release", detail: nil, isUnread: false)
            }
        }
    }
}

private struct ActivityAnnouncementSectionHeading: View {
    let title: LocalizedStringResource
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ActivityAnnouncementHeroMark: View {
    var body: some View {
        Image(systemName: "rectangle.split.3x1")
            .font(.system(size: 29, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(
                LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: .rect(cornerRadius: 20)
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.cyan)
                    .frame(width: 14, height: 14)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
                    .offset(x: 4, y: -4)
            }
            .rotationEffect(.degrees(-6))
            .accessibilityHidden(true)
    }
}

private struct ActivityAnnouncementRow: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource?
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUnread ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(isUnread ? Color.accentColor.opacity(0.25) : .clear) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? Text("Unread") : Text("Read"))
    }
}
