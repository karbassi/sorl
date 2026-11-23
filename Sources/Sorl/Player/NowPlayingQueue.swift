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
    /// What the queue shows. The current item takes the details published as Now Playing.
    /// `@unchecked`: `MPMediaItemArtwork` isn't marked Sendable, but it's never mutated and its image closure is.
    struct Snapshot: Equatable, @unchecked Sendable {
        var upNext: UpNext
        var title: String
        var subtitle: String?
        var album: String?
        var duration: Double?
        var artwork: MPMediaItemArtwork?
        /// Once a data source is installed, the system takes the playing item's position and the rest of
        /// `nowPlayingInfo` (chapters, queue index) from the current content item, not from the center.
        var elapsed: Double
        var rate: Double
        var defaultRate: Double
        /// `nowPlayingInfo` without its artwork, which MediaRemote can't encode inside a content item.
        var info: NSDictionary
    }

    /// `@unchecked`: the content item is only touched under the lock or on the main actor, as MediaPlayer expects.
    private struct State: @unchecked Sendable {
        var snapshot: Snapshot?
        /// The current item as handed to the system. It keeps this object and listens for its changes, so updates
        /// go to this same object; a new one with the same identifier is ignored.
        var current: MPContentItem?
    }

    private static let setDataSource = NSSelectorFromString("setPlaybackQueueDataSource:")
    private static let invalidate = NSSelectorFromString("invalidatePlaybackQueue")

    /// Whether this macOS takes a queue data source.
    static func isSupported(by center: MPNowPlayingInfoCenter) -> Bool {
        center.responds(to: setDataSource) && center.responds(to: invalidate)
    }

    /// Main actor only, from `publish`.
    private var installed = false

    // MediaPlayer reads the queue on its own queue.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Shares `next` (nil shares nothing). Changes to the playing item update its content item in place; only a changed
    /// queue makes the system reread it.
    func publish(_ next: Snapshot?, to center: MPNowPlayingInfoCenter) {
        let (previous, current) = state.withLockUnchecked { state in
            let previous = state.snapshot
            state.snapshot = next
            if next?.upNext.current?.id != previous?.upNext.current?.id { state.current = nil }
            return (previous, state.current)
        }
        guard next != previous, Self.isSupported(by: center) else { return }
        if let next, let current { Self.apply(next, to: current) }
        // Installed once and kept: removing a data source and setting it again leaves Now Playing empty.
        if next != nil, !installed {
            installed = true
            center.perform(Self.setDataSource, with: self)
        }
        if let next, next.upNext != previous?.upNext { center.perform(Self.invalidate) }
    }

    @objc(nowPlayingInfoCenter:contentItemIDForOffset:)
    func contentItemID(_ center: MPNowPlayingInfoCenter, forOffset offset: Int) -> String? {
        state.withLock { $0.snapshot?.upNext.item(atOffset: offset)?.id.uuidString }
    }

    @objc(nowPlayingInfoCenter:contentItemIDsFromOffset:toOffset:nowPlayingIndex:)
    func contentItemIDs(_ center: MPNowPlayingInfoCenter, from: Int, to: Int,
                        nowPlayingIndex: UnsafeMutablePointer<Int>?) -> [String] {
        let (items, currentIndex) = state.withLock { $0.snapshot?.upNext.items(fromOffset: from, toOffset: to) } ?? ([], nil)
        nowPlayingIndex?.pointee = currentIndex ?? NSNotFound
        return items.map(\.id.uuidString)
    }

    @objc(nowPlayingInfoCenter:contentItemForID:)
    func contentItem(_ center: MPNowPlayingInfoCenter, forID identifier: String) -> MPContentItem? {
        guard let id = UUID(uuidString: identifier) else { return nil }
        return state.withLockUnchecked { state -> MPContentItem? in
            guard let snapshot = state.snapshot, let item = snapshot.upNext.item(withID: id) else { return nil }
            if item.id == snapshot.upNext.current?.id {
                if let current = state.current { return current }
                guard let content = Self.makeContentItem(identifier) else { return nil }
                Self.apply(snapshot, to: content)
                state.current = content
                return content
            }
            guard let content = Self.makeContentItem(identifier) else { return nil }
            content.title = item.title
            content.isPlayable = true
            Self.set(item.duration, "duration", on: content)
            return content
        }
    }

    /// Writes the playing item's details onto its content item; the item reports the change to the system itself.
    private static func apply(_ snapshot: Snapshot, to content: MPContentItem) {
        set(snapshot.info, "nowPlayingInfo", on: content)
        content.title = snapshot.title
        content.isPlayable = true
        // Marks the item as having a cover; the system then fetches it through `artwork(_:for:size:completion:)`.
        if let artwork = snapshot.artwork, content.artwork !== artwork {
            content.artwork = artwork
            // Known gap: the system doesn't fetch a cover that arrives after it first read the item.
        }
        set(snapshot.album, "albumName", on: content)
        set(snapshot.subtitle, "trackArtistName", on: content)
        set(snapshot.duration ?? snapshot.upNext.current?.duration, "duration", on: content)
        set(snapshot.defaultRate, "defaultPlaybackRate", on: content)
        set(snapshot.rate, "playbackRate", on: content)
        set(snapshot.elapsed, "elapsedTime", on: content)
    }

    /// The playing item's cover. With a data source installed, the system asks here instead of reading the artwork in
    /// `nowPlayingInfo`. The block's argument types aren't public; it takes the image first (an `NSImage` works).
    @objc(nowPlayingInfoCenter:artworkForContentItem:size:completion:)
    func artwork(_ center: MPNowPlayingInfoCenter, for item: MPContentItem, size: CGSize,
                 completion: @escaping @convention(block) (AnyObject?, AnyObject?) -> Void) {
        let id = item.identifier
        let current = state.withLock { $0.snapshot }
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

