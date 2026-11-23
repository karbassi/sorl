import Foundation
import MediaPlayer
import os
import SorlCore

/// The name MediaPlayer checks a playback queue data source against. Declaring it here registers the same protocol,
/// so `NowPlayingQueue` conforms to it.
@objc(MPNowPlayingPlaybackQueueDataSource) private protocol PlaybackQueueDataSource: NSObjectProtocol {}

/// Shares Up next with the system Now Playing queue, so widgets that read a player's queue can list it.
///
/// macOS has no public API for this: `MPNowPlayingInfoCenter` takes a queue data source only through its private
/// `setPlaybackQueueDataSource:`, the hook Apple's own players use. Every private call is checked first; when one is
/// missing, Sorl publishes the queue position and length only, as before.
nonisolated final class NowPlayingQueue: NSObject, PlaybackQueueDataSource, @unchecked Sendable {
    /// What the queue shows. The current item takes the title, subtitle and length published as Now Playing.
    /// `@unchecked`: `MPMediaItemArtwork` isn't marked Sendable, but it's never mutated and its image closure is.
    struct Snapshot: Equatable, @unchecked Sendable {
        var upNext: UpNext
        var title: String
        var subtitle: String?
        var album: String?
        var duration: Double?
        var artwork: MPMediaItemArtwork?
        /// The full `nowPlayingInfo`: the system takes elapsed time, rate, chapters and queue position from the
        /// current item once a data source is installed, not from the center.
        var info: NSDictionary
    }

    private static let setDataSource = NSSelectorFromString("setPlaybackQueueDataSource:")
    private static let invalidate = NSSelectorFromString("invalidatePlaybackQueue")

    /// Whether this macOS takes a queue data source.
    static func isSupported(by center: MPNowPlayingInfoCenter) -> Bool {
        center.responds(to: setDataSource) && center.responds(to: invalidate)
    }

    // MediaPlayer reads the queue on its own queue.
    private let snapshot = OSAllocatedUnfairLock<Snapshot?>(initialState: nil)

    /// Shares `next` (nil stops sharing) and tells the system the queue changed.
    func publish(_ next: Snapshot?, to center: MPNowPlayingInfoCenter) {
        let previous = snapshot.withLock { state in defer { state = next }; return state }
        guard next != previous, Self.isSupported(by: center) else { return }
        if (previous == nil) != (next == nil) { center.perform(Self.setDataSource, with: next == nil ? nil : self) }
        if next != nil { center.perform(Self.invalidate) }
    }

    @objc(nowPlayingInfoCenter:contentItemIDForOffset:)
    func contentItemID(_ center: MPNowPlayingInfoCenter, forOffset offset: Int) -> String? {
        snapshot.withLock { $0?.upNext.item(atOffset: offset)?.id.uuidString }
    }

    @objc(nowPlayingInfoCenter:contentItemIDsFromOffset:toOffset:nowPlayingIndex:)
    func contentItemIDs(_ center: MPNowPlayingInfoCenter, from: Int, to: Int,
                        nowPlayingIndex: UnsafeMutablePointer<Int>?) -> [String] {
        let (items, currentIndex) = snapshot.withLock { $0?.upNext.items(fromOffset: from, toOffset: to) } ?? ([], nil)
        nowPlayingIndex?.pointee = currentIndex ?? NSNotFound
        return items.map(\.id.uuidString)
    }

    @objc(nowPlayingInfoCenter:contentItemForID:)
    func contentItem(_ center: MPNowPlayingInfoCenter, forID identifier: String) -> MPContentItem? {
        guard let id = UUID(uuidString: identifier),
              let (item, snapshot) = snapshot.withLock({ state in state.flatMap { s in s.upNext.item(withID: id).map { ($0, s) } } }),
              let content = Self.makeContentItem(identifier) else { return nil }
        let isCurrent = item.id == snapshot.upNext.current?.id
        content.title = isCurrent ? snapshot.title : item.title
        content.isPlayable = true
        // Marks the item as having a cover; the system then fetches it through `artwork(_:for:size:completion:)`.
        if isCurrent, let artwork = snapshot.artwork {
            content.artwork = artwork
            // A new identifier when the cover arrives after the item was first read, so the system fetches it again.
            Self.set(String(UInt(bitPattern: ObjectIdentifier(artwork).hashValue)), "artworkIdentifier", on: content)
        }
        Self.set(isCurrent ? snapshot.info : nil, "nowPlayingInfo", on: content)
        Self.set(isCurrent ? snapshot.album : nil, "albumName", on: content)
        Self.set(isCurrent ? snapshot.subtitle : nil, "trackArtistName", on: content)
        Self.set(isCurrent ? snapshot.duration ?? item.duration : item.duration, "duration", on: content)
        return content
    }

    /// The playing item's cover. With a data source installed, the system asks here instead of reading the artwork in
    /// `nowPlayingInfo`. The block's argument types aren't public; it takes the image first (an `NSImage` works).
    @objc(nowPlayingInfoCenter:artworkForContentItem:size:completion:)
    func artwork(_ center: MPNowPlayingInfoCenter, for item: MPContentItem, size: CGSize,
                 completion: @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) {
        let id = item.identifier
        let current = snapshot.withLock { $0 }
        let art = current?.upNext.current?.id.uuidString == id ? current?.artwork : nil
        completion(art?.image(at: size), nil)
    }

    /// An `MPNowPlayingContentItem`, the private subclass that carries an artist and length, else a plain content item.
    private static func makeContentItem(_ identifier: String) -> MPContentItem? {
        guard let type = NSClassFromString("MPNowPlayingContentItem"), type.isSubclass(of: MPContentItem.self) else {
            return MPContentItem(identifier: identifier)
        }
        // `init(identifier:)` is not `required`, so Swift cannot call it on a class only known at run time.
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer, Selector, NSString) -> Unmanaged<MPContentItem>?
        let alloc = NSSelectorFromString("alloc"), initialize = #selector(MPContentItem.init(identifier:))
        // class_getMethodImplementation never returns nil (a missing method gets the forwarding IMP), so check first.
        guard class_respondsToSelector(object_getClass(type), alloc), class_respondsToSelector(type, initialize),
              let allocIMP = class_getMethodImplementation(object_getClass(type), alloc),
              let initIMP = class_getMethodImplementation(type, initialize),
              let raw = unsafeBitCast(allocIMP, to: Alloc.self)(type, alloc) else { return MPContentItem(identifier: identifier) }
        return unsafeBitCast(initIMP, to: Initialize.self)(raw, initialize, identifier as NSString)?.takeRetainedValue()
    }

    private static func set(_ value: Any?, _ key: String, on item: MPContentItem) {
        guard let value, item.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) else { return }
        item.setValue(value, forKey: key)
    }
}

