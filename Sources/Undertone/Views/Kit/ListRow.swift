import SwiftUI

/// The one row every list uses (Up next, Saved, Recent, F5): a 32pt thumbnail, a one-line title and trailing text,
/// 42pt tall. On hover or focus the row turns gray and its hover controls replace the trailing text in place.
struct ListRow: View {
    enum Trailing: Equatable {
        case text(String)
        case nowPlaying
        case none
    }

    enum HoverAction: Hashable {
        case add, remove
    }

    /// The Recent thumbnail bar: a blue position, or a full gray bar once finished.
    enum Progress: Equatable {
        case position(Double)
        case finished
    }

    let id: String
    let title: String
    var thumbnail: URL?
    var trailing: Trailing = .none
    var downloaded = false
    var progress: Progress?
    var isCurrent = false
    var hoverActions: [HoverAction] = []
    /// Up next rows show a drag grip over the thumbnail on hover.
    var reorderable = false
    /// What the remove button and its accessibility action say ("Remove from Saved").
    var removeLabel = "Remove"
    var onTap: () -> Void = {}
    var onAdd: () -> Void = {}
    var onRemove: () -> Void = {}
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    /// The demo harness forces hover by this key (the item's cache key), since row ids are random.
    var hoverKey: String?
    /// The grip's drag, in the list's coordinate space: the vertical translation, then the end.
    var onDragChanged: ((DragGesture.Value) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Lifted while being dragged: white with a shadow.
    var isDragging = false
    /// Briefly marked after being added (G3).
    var isHighlighted = false

    @State private var hovering = false
    @FocusState private var focused: Bool
    @Environment(\.forcedHover) private var forcedHover

    private var showsControls: Bool {
        !isCurrent && (hovering || focused || isDragging || (forcedHover != nil && [id, hoverKey, title].contains(forcedHover)))
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
            Text(title)
                .font(isCurrent ? PanelStyle.title : PanelStyle.row)
                .foregroundStyle(isCurrent ? PanelStyle.currentText : PanelStyle.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingView
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(height: PanelStyle.rowHeight)
        .background(background, in: .rect(cornerRadius: PanelStyle.rowRadius))
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 9, y: 6)
        .overlay {
            if isDragging { RoundedRectangle(cornerRadius: PanelStyle.rowRadius).strokeBorder(.black.opacity(0.06)) }
        }
        .contentShape(.rect(cornerRadius: PanelStyle.rowRadius))
        .onTapGesture(perform: onTap)
        .onPanelHover { hovering = $0 }
        // Rows take focus only with Full Keyboard Access, like other macOS lists; otherwise the panel would focus
        // (and highlight) the first row every time it opens.
        .focusable(NSApp.isFullKeyboardAccessEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return) { onTap(); return .handled }
        .onKeyPress(.space) { onTap(); return .handled }
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            guard press.modifiers.contains(.option) else { return .ignored }
            let move = press.key == .upArrow ? onMoveUp : onMoveDown
            guard let move else { return .ignored }
            move()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { onTap() }
        .modifier(RowActions(row: self))
    }

    private var background: Color {
        if isCurrent { return PanelStyle.currentRow }
        if isDragging { return PanelStyle.drawerSurface }
        return showsControls || isHighlighted ? PanelStyle.hoverRow : .clear
    }

    private var thumbnailView: some View {
        Thumbnail(url: thumbnail)
            .overlay(alignment: .bottom) {
                if let progress { ProgressStrip(progress: progress) }
            }
            .clipShape(.rect(cornerRadius: PanelStyle.thumbRadius))
            .overlay {
                if reorderable {
                    RoundedRectangle(cornerRadius: PanelStyle.thumbRadius)
                        .fill(.black.opacity(0.45))
                        .overlay { GripDots() }
                        .opacity(showsControls ? 1 : 0)
                        .help("Drag to reorder")
                        .accessibilityHidden(true)
                        .gesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .named(ListRow.dragSpace))
                                .onChanged { onDragChanged?($0) }
                                .onEnded { _ in onDragEnded?() }
                        )
                        .pointerStyle(isDragging ? .grabActive : .grabIdle)
                }
            }
    }

    @ViewBuilder private var trailingView: some View {
        ZStack(alignment: .trailing) {
            trailingText.opacity(showsControls && !hoverActions.isEmpty ? 0 : 1)
            if !hoverActions.isEmpty {
                HStack(spacing: 6) {
                    if hoverActions.contains(.add) {
                        SymbolButton(symbol: "plus", label: "Add to up next", size: 15, weight: .regular, side: 24,
                                     tint: PanelStyle.accent, action: onAdd)
                    }
                    if hoverActions.contains(.remove) {
                        SymbolButton(symbol: "xmark", label: removeLabel, size: 13, weight: .regular, side: 24, action: onRemove)
                    }
                }
                .revealed(showsControls)
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var trailingText: some View {
        switch trailing {
        case .text(let text):
            HStack(spacing: 4) {
                if downloaded {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 9, weight: .medium))
                        .frame(width: 11, height: 11)
                        .help("Downloaded, plays offline")
                        .accessibilityLabel("Downloaded")
                }
                Text(text)
            }
            .font(PanelStyle.meta)
            .foregroundStyle(PanelStyle.secondary)
        case .nowPlaying:
            Text("Now playing")
                .font(PanelStyle.meta)
                .foregroundStyle(PanelStyle.currentText)
        case .none:
            EmptyView()
        }
    }

    /// The coordinate space reorder drags are measured in.
    static let dragSpace = "list-drag"

    private var accessibilityLabel: String {
        var parts = [title]
        switch trailing {
        case .text(let t): parts.append(t)
        case .nowPlaying: parts.append("Now playing")
        case .none: break
        }
        if downloaded { parts.append("Downloaded") }
        if progress == .finished { parts.append("Finished") }
        return parts.joined(separator: ", ")
    }
}

/// Accessibility actions mirroring the hover controls, so nothing depends on a mouse.
private struct RowActions: ViewModifier {
    let row: ListRow

    func body(content: Content) -> some View {
        content
            .accessibilityActions {
                if !row.isCurrent, row.hoverActions.contains(.add) {
                    Button("Add to up next", action: row.onAdd)
                }
                if !row.isCurrent, row.hoverActions.contains(.remove) {
                    Button(row.removeLabel, action: row.onRemove)
                }
                if let up = row.onMoveUp { Button("Move up", action: up) }
                if let down = row.onMoveDown { Button("Move down", action: down) }
            }
    }
}

/// The 3pt bar along the bottom of a Recent thumbnail.
private struct ProgressStrip: View {
    let progress: ListRow.Progress

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.25))
                switch progress {
                case .position(let fraction):
                    Rectangle().fill(PanelStyle.toastAction)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
                case .finished:
                    Rectangle().fill(Color(hex: 0xC7C7CC))
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A Played row: text only, gray, indented (Up next's "Played (n)" disclosure).
struct PlayedRow: View {
    let title: String
    var onTap: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(PanelStyle.small)
            .foregroundStyle(PanelStyle.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .padding(.leading, 26)
            .padding(.trailing, 6)
            .frame(height: 25)
            .background(hovering ? PanelStyle.hoverRow : .clear, in: .rect(cornerRadius: PanelStyle.rowRadius))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onPanelHover { hovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), played")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Play again", onTap)
    }
}

/// Six white dots in two columns: the drag grip over an Up next thumbnail.
private struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.white)
    }
}
