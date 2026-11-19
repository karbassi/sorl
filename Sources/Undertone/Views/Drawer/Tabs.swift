import SwiftUI
import UndertoneCore

struct SavedTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(hint: "Click to play. + adds to up next.")
            ScrollingList(accessibilityLabel: "Saved") {
                ForEach(settings.saved.items) { item in
                    ListRow(id: item.id, title: item.title, thumbnail: Thumbnail.url(for: item.url),
                            trailing: item.trailingText.map { .text($0) } ?? .none)
                }
            }
        }
    }
}

struct RecentTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(hint: "Click to resume. + adds to up next.")
            ScrollingList(accessibilityLabel: "Recent") {
                ForEach(settings.recent.grouped(), id: \.group) { group in
                    Text(group.group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PanelStyle.tertiary)
                        .padding(EdgeInsets(top: 8, leading: 6, bottom: 2, trailing: 6))
                    ForEach(group.items) { item in
                        ListRow(id: item.id, title: item.title, thumbnail: Thumbnail.url(for: item.url),
                                trailing: item.trailingText.map { .text($0) } ?? .none)
                    }
                }
            }
        }
    }
}
