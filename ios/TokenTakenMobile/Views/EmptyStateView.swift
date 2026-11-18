import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink1)

            Text(message)
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)

            if model.state == .noReport || model.state == .iCloudUnavailable {
                Text("Open Token Taken on your Mac, go to Settings, and turn on Sync to iPhone. Your Mac and this iPhone must use the same Apple ID.")
                    .font(.callout)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    Task { await model.setDemoMode(true) }
                } label: {
                    Text("View sample data")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await model.reload() }
                } label: {
                    Text("Try again")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch model.state {
        case .downloading: "icloud.and.arrow.down"
        case .unsupportedVersion: "arrow.down.circle"
        case .decodeFailed: "exclamationmark.triangle"
        case .iCloudUnavailable: "icloud.slash"
        default: "icloud"
        }
    }

    private var title: LocalizedStringKey {
        switch model.state {
        case .downloading: "Downloading report"
        case .unsupportedVersion: "Update Token Taken"
        case .decodeFailed: "Couldn't read the report"
        case .iCloudUnavailable: "iCloud is unavailable"
        default: "No report yet"
        }
    }

    private var message: LocalizedStringKey {
        switch model.state {
        case .downloading:
            "Waiting for iCloud to finish downloading your report. Try again in a moment."
        case .unsupportedVersion:
            "The report in iCloud uses a newer format than this version of the app supports."
        case .decodeFailed:
            "The report file couldn't be decoded. Try again, or open Token Taken on your Mac."
        case .iCloudUnavailable:
            "Sign in to iCloud, then try again."
        default:
            "Waiting for the first report from your Mac."
        }
    }
}
