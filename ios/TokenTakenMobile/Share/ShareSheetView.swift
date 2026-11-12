import SwiftUI
import UIKit

/// Preview plus `ShareLink`. Saving to Photos happens inside the system share sheet,
/// so the app asks for no photo-library permission.
struct ShareSheetView: View {
    let card: ShareCardView

    @Environment(\.dismiss) private var dismiss
    @State private var preview: UIImage?
    @State private var fileURL: URL?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 300, maxHeight: 380)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                    } else if failed {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                            Text("Couldn't render the card.")
                                .font(.callout)
                        }
                        .foregroundStyle(Palette.ink2)
                    } else {
                        ProgressView("Rendering the card…")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 380)

                if let preview, let fileURL {
                    ShareLink(
                        item: fileURL,
                        preview: SharePreview("Token Taken", image: Image(uiImage: preview))
                    ) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: 300)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Palette.solid.ignoresSafeArea())
            .navigationTitle("Share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { render() }
        }
    }

    private func render() {
        guard preview == nil else { return }
        guard let image = ShareCardRenderer.image(for: card, scale: 2) else {
            failed = true
            return
        }
        preview = image
        fileURL = ShareCardRenderer.writePNG(image)
    }
}
