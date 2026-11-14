import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Demo mode", isOn: demoBinding)
                } header: {
                    Text("Sample data")
                } footer: {
                    Text("Demo mode shows synthetic data. Turn it off to read your own reports.")
                }

                Section {
                    Text(verbatim: Ranking.methodology(locale: locale))
                        .font(.footnote)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Rank curve version") {
                        Text(verbatim: UsageRank.version)
                    }
                } header: {
                    Text("Ranking")
                }

                Section {
                    LabeledContent("Version") {
                        Text(verbatim: appVersion)
                    }
                    LabeledContent("Report schema") {
                        Text(verbatim: "v1")
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text("Reports come from Macs signed in to the same Apple ID.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var demoBinding: Binding<Bool> {
        Binding(
            get: { model.demoMode },
            set: { enabled in Task { await model.setDemoMode(enabled) } }
        )
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
