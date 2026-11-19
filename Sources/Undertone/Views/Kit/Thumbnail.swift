import SwiftUI
import UndertoneCore

/// Square artwork with a rounded corner: 32pt in rows, 40pt in the mini player, 64pt in the player. While the image
/// loads (or when there is none) it shows the dark placeholder from the design.
struct Thumbnail: View {
    let url: URL?
    var side: CGFloat = PanelStyle.thumbSide
    var radius: CGFloat = PanelStyle.thumbRadius
    @State private var image: NSImage?

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
                guard let url else { image = nil; return }
                image = ArtworkLoader.shared.cached(url)
                if image == nil { image = await ArtworkLoader.shared.image(for: url) }
            }
    }

    /// YouTube's medium thumbnail for a video id.
    static func url(videoID: String?) -> URL? {
        videoID.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") }
    }

    static func url(for link: URL) -> URL? {
        url(videoID: LinkParser.parse(link.absoluteString)?.videoID)
    }
}
