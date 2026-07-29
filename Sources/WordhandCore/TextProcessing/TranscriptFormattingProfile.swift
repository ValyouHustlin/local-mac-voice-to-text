import Foundation

public enum TranscriptFormattingProfile: String, Codable, CaseIterable, Sendable {
    case automatic
    case polished
    case aiPrompt
    case verbatim

    public func resolved(for target: TranscriptTarget) -> TranscriptFormattingProfile {
        guard self == .automatic else { return self }

        let identifier = target.bundleIdentifier?.lowercased() ?? ""
        let name = target.applicationName?.lowercased() ?? ""
        let aiAndDevelopmentTargets = [
            "terminal", "iterm", "warp", "ghostty", "alacritty", "kitty",
            "wezterm", "hyper", "tabby", "rio", "cursor", "windsurf",
            "visual studio code", "vscode", "xcode", "zed", "chatgpt", "claude",
        ]
        if aiAndDevelopmentTargets.contains(where: {
            identifier.contains($0.replacingOccurrences(of: " ", with: ""))
                || name.contains($0)
        }) {
            return .aiPrompt
        }
        return .polished
    }
}
