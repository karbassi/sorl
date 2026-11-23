import Foundation

/// Picks the playable link out of what was dragged onto the menu bar icon: a URL from a browser's address bar or a
/// page, the text of a link, or the contents of a `.webloc` file.
public enum DroppedLink {
    /// The first candidate that is exactly one playable link, or nil. Candidates come in pasteboard order (URLs before
    /// plain text); a candidate holding prose, several links or nothing link-like is skipped, so dragging a paragraph
    /// that mentions a link is refused rather than guessed at.
    public static func link(from candidates: [String]) -> MediaLink? {
        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 2048, !text.contains(where: \.isWhitespace) else { continue }
            if let link = LinkParser.parse(text) { return link }
        }
        return nil
    }

    /// The URL string a `.webloc` file points at. Finder writes them as property lists with a `URL` key (XML or
    /// binary); anything else gives nil.
    public static func weblocURL(from data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let url = plist["URL"] as? String
        else { return nil }
        return url
    }
}
