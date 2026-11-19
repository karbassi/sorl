import SwiftUI

/// Where a `ScrollingList` is scrolled, for drag auto-scroll.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

/// The scrolling middle of every tab. A 36pt fade sits at the bottom edge; a 28pt fade at the top appears once the
/// list is scrolled. The content keeps the drawer's 16pt side inset and a little room at the end.
struct ScrollingList<Content: View>: View {
    var accessibilityLabel: String
    var fadeColor: Color = PanelStyle.drawerSurface
    var spacing: CGFloat = 0
    var position: Binding<ScrollPosition>?
    var metrics: Binding<ScrollMetrics>?
    @ViewBuilder var content: () -> Content
    @State private var ownPosition = ScrollPosition()
    @State private var scrolled = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(.horizontal, PanelStyle.drawerInset)
            .padding(.bottom, 8)
        }
        .scrollPosition(position ?? $ownPosition)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
            ScrollMetrics(offset: geo.contentOffset.y + geo.contentInsets.top, viewport: geo.containerSize.height,
                          content: geo.contentSize.height)
        } action: { _, value in
            scrolled = value.offset > 1
            metrics?.wrappedValue = value
        }
        .overlay(alignment: .top) {
            LinearGradient(colors: [fadeColor, fadeColor.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: PanelStyle.topFade)
                .opacity(scrolled ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [fadeColor.opacity(0), fadeColor], startPoint: .top, endPoint: .bottom)
                .frame(height: PanelStyle.bottomFade)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// An empty list: a 13pt semibold title and one or two 12pt lines under it, centered (G4, G5, empty Saved and Recent).
struct EmptyListMessage: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(PanelStyle.title)
                .foregroundStyle(PanelStyle.text)
            Text(message)
                .font(PanelStyle.small)
                .lineSpacing(2)
                .foregroundStyle(PanelStyle.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(EdgeInsets(top: 28, leading: 12, bottom: 8, trailing: 12))
        .accessibilityElement(children: .combine)
    }
}
