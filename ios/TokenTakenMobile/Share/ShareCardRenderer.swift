import SwiftUI
import UIKit

@MainActor
enum ShareCardRenderer {
    static func image(for card: ShareCardView, scale: CGFloat = 2) -> UIImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// A stable temp file, so repeated shares never pile up copies.
    static func writePNG(_ image: UIImage) -> URL? {
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Token-Taken-share-card.png", isDirectory: false)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }
}
