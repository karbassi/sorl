import SwiftUI
import SorlCore

/// F7: a problem that needs action, as one slim row (36pt, an orange "!", one short line, one action).
/// yt-dlp missing, broken or outdated says "Fix…" and opens Settings; a failed load says "Try again".
/// On the player it sits above the Up next bar (the player grows 44pt); in the drawer, under the mini player;
/// on Nothing playing, at the top.
struct ProblemBanner: View {
    @Environment(PlayerEngine.self) private var engine
    @Environment(YTDLPService.self) private var service
    @Environment(PanelState.self) private var state

    var body: some View {
        if let problem = Self.problem(engine: engine, service: service) {
            HStack(spacing: 8) {
                Text("!")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color(hex: 0xFF8A00)))
                    .accessibilityHidden(true)
                Text(problem.message)
                    .font(PanelStyle.small)
                    .foregroundStyle(PanelStyle.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(problem.detail ?? problem.message)
                Button {
                    switch problem {
                    case .tool: state.showSettings(true)
                    case .failed: engine.retry()
                    }
                } label: {
                    Text(problem.action)
                        .font(PanelStyle.smallBold)
                        .foregroundStyle(PanelStyle.accent)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(problem.actionHint)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(width: PanelStyle.width - 28, height: PanelStyle.bannerHeight)
            .background(PanelStyle.warningFill, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xC45A00, opacity: 0.25), lineWidth: 0.5))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Problem: \(problem.message)")
        }
    }

    enum Problem {
        case tool(detail: String)
        case failed(message: String, suggestion: String?)

        var message: String {
            switch self {
            case .tool: return "Videos can't play right now"
            case .failed(let message, _): return message
            }
        }

        var detail: String? {
            switch self {
            case .tool(let detail): return detail
            case .failed(_, let suggestion): return suggestion
            }
        }

        var action: String {
            switch self {
            case .tool: return "Fix…"
            case .failed: return "Try again"
            }
        }

        var actionHint: String {
            switch self {
            case .tool: return "Opens Settings"
            case .failed: return "Loads the video again"
            }
        }
    }

    /// yt-dlp first, since a failed load usually follows from it.
    static func problem(engine: PlayerEngine, service: YTDLPService) -> Problem? {
        switch service.status {
        case .missing: return .tool(detail: "yt-dlp isn't installed")
        case .broken(let message): return .tool(detail: "yt-dlp isn't working: \(message)")
        case .outdated(let version): return .tool(detail: "yt-dlp \(version) is older than YouTube likes")
        case .checking, .ready: break
        }
        if let message = engine.errorMessage { return .failed(message: message, suggestion: engine.errorSuggestion) }
        return nil
    }

    static func isShowing(engine: PlayerEngine, service: YTDLPService) -> Bool {
        problem(engine: engine, service: service) != nil
    }
}
