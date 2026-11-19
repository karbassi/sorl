import SwiftUI
import UndertoneCore

/// Up next: what's coming. (Read-only here; editing lands with the Up next tab.)
struct UpNextTab: View {
    @Environment(PlayerEngine.self) private var engine

    var body: some View {
        let queue = engine.upNext
        VStack(spacing: 10) {
            SectionHeader(label: queue.headerSource.map { "From \($0)" } ?? "Up next",
                          detail: queue.isEmpty ? nil : "\(queue.upcoming.count) left")
            ScrollingList(accessibilityLabel: "Up next") {
                ForEach(queue.upcoming) { item in
                    ListRow(id: item.id.uuidString, title: item.title, thumbnail: Thumbnail.url(videoID: item.videoID),
                            trailing: item.duration.map { .text(TimeFormat.clock($0)) } ?? .none,
                            downloaded: engine.downloadedKeys.contains(item.cacheKey))
                }
            }
        }
    }
}

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
