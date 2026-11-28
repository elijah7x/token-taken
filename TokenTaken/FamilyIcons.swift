import SwiftUI

struct SourceIcon: View {
    let sourceID: String
    let name: String
    var size: CGFloat = 18

    private var assetName: String? {
        switch sourceID.lowercased() {
        case "claude": "provider-claude"
        case "codex": "provider-codex"
        case "zcode": "provider-zcode"
        case "pi": "provider-pi"
        case "kimi": "provider-kimi"
        case "devin": "provider-devin"
        case "antigravity": "provider-antigravity"
        case "cursor": "provider-cursor"
        case "mcode": "provider-minimaxCode"
        case "omp": "provider-omp"
        case "grok": "provider-grok"
        case "opencode": "provider-opencode"
        case "dsh", "deepseek-cli": "provider-deepseek"
        default: nil
        }
    }

    private var usesAdaptiveTemplate: Bool {
        guard let assetName else { return false }
        return ["provider-codex", "provider-zcode", "provider-devin", "provider-cursor", "provider-grok", "provider-opencode"].contains(assetName)
    }

    var body: some View {
        if let assetName {
            let useTemplate = ThemeRuntime.isCosmos || usesAdaptiveTemplate
            Image(assetName)
                .renderingMode(useTemplate ? .template : .original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(useTemplate ? Palette.ink2 : Color.primary)
                .accessibilityHidden(true)
        } else {
            SourceMonogramBadge(sourceID: sourceID, name: name, size: size)
        }
    }
}
