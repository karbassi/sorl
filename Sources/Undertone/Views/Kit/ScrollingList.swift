import SwiftUI

/// The scrolling middle of every tab. A 36pt fade sits at the bottom edge; a 28pt fade at the top appears once the
/// list is scrolled. The content keeps the drawer's 16pt side inset and a little room at the end.
struct ScrollingList<Content: View>: View {
    var accessibilityLabel: String
    var fadeColor: Color = PanelStyle.drawerSurface
    @ViewBuilder var content: () -> Content
    @State private var scrolled = false
    @State private var canScrollDown = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, PanelStyle.drawerInset)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: [Bool].self) { geo in
            let offset = geo.contentOffset.y + geo.contentInsets.top
            let remaining = geo.contentSize.height - geo.containerSize.height - offset
            return [offset > 1, remaining > 1]
        } action: { _, flags in
            scrolled = flags[0]
            canScrollDown = flags[1]
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
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
