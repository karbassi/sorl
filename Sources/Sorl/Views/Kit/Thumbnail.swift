import SwiftUI
import SorlCore

/// Square artwork with a rounded corner: 32pt in rows, 40pt in the mini player, 64pt in the player. While the image
/// loads (or when there is none) it shows the dark placeholder from the design.
struct Thumbnail: View {
    let url: URL?
    var side: CGFloat = PanelStyle.thumbSide
    var radius: CGFloat = PanelStyle.thumbRadius
    /// What the fetch below returned, keyed by its URL so a stale image never shows for a new one.
    @State private var fetched: (url: URL, image: NSImage)?

    /// Read from the cache in `body`, not only in `.task`: `.task` runs after the first frame, so a page sliding in
    /// would show the placeholder and then pop the art in mid-slide.
    private var image: NSImage? {
        guard let url else { return nil }
        if let fetched, fetched.url == url { return fetched.image }
        return ArtworkLoader.shared.cached(url)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(PanelStyle.artPlaceholder)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: radius))
            .accessibilityHidden(true)
            .task(id: url) {
                guard let url, ArtworkLoader.shared.cached(url) == nil else { return }
                if let loaded = await ArtworkLoader.shared.image(for: url) { fetched = (url, loaded) }
            }
    }

    /// YouTube's medium thumbnail for a video id.
    /// Nil for the demo harness's made-up ids, which draw the placeholder like the design screens.
    static func url(videoID: String?) -> URL? {
        guard let videoID, !videoID.hasPrefix(DemoFixtures.idPrefix) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    static func url(for link: URL) -> URL? {
        url(videoID: LinkParser.parse(link.absoluteString)?.videoID)
    }
}
