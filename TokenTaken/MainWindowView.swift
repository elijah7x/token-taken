import Observation
import SwiftUI
import TokenTakenKit

@Observable
@MainActor
final class MainWindowRouter {
    enum Route: Equatable {
        case dashboard
        case settings
    }

    var route: Route = .dashboard
}

/// Two-column main window: summary rail on the left, the selected hero view
/// with source and model lists on the right.
struct MainWindowView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch router.route {
            case .dashboard:
                dashboard
                    .transition(.opacity)
            case .settings:
                SettingsView()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowBackdrop(theme: settings.theme, transparency: settings.interfaceTransparency) }
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: router.route)
    }

    private var dashboard: some View {
        VStack(spacing: 0) {
            TitleRow()
            PeriodBar()
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        SummaryRail(summary: model.summary)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 22)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: .infinity)

                    RailSettingsButton()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                }
                .frame(width: 284)

                Rectangle().fill(Palette.hairline).frame(width: 1)

                VStack(spacing: 16) {
                    if model.isEmpty {
                        ContentUnavailableView {
                            Label("No usage collected yet", systemImage: "drop")
                        } description: {
                            Text("Token Taken reads supported agent logs on this Mac. Use Refresh now in Settings, or wait for the first collection to finish.")
                        } actions: {
                            Button("Open Settings…") { router.route = .settings }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Group {
                            switch settings.heroStyle {
                            case .confluence:
                                ConfluenceView(summary: model.summary)
                            case .condensation:
                                CondensationView(summary: model.summary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
                        BreakdownColumns(summary: model.summary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 18)
            }
        }
    }
}

/// Keeps the hidden title bar band clear for the traffic lights.
private struct TitleRow: View {
    var body: some View {
        Color.clear
            .frame(height: 30)
            .padding(.top, 2)
    }
}

private struct RailSettingsButton: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            router.route = .settings
        } label: {
            SettingsGlyph(size: 18, isHovered: isHovered)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailSettingsButtonStyle(reduceMotion: reduceMotion))
        .onHover { isHovered = $0 }
        .help(Text("Settings"))
        .accessibilityLabel(Text("Settings"))
    }
}

private struct RailSettingsButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct PeriodBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 16) {
            PeriodPicker()
            Text(rangeTitle)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(Palette.liveDot).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                // Relative time ("5 min ago") must re-render as the clock advances.
                TimelineView(.everyMinute) { _ in Text(model.statusText) }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 50)
    }

    private var rangeTitle: LocalizedStringKey {
        let start = model.summary.start
        switch model.period {
        case .day:
            return "Today · \(start.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return "This month · \(start.formatted(.dateTime.year().month(.wide)))"
        case .year:
            return "This year · \(start.formatted(.dateTime.year()))"
        case .all:
            return "All time · since \(start.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))"
        }
    }
}

/// Segmented control whose selection is a native glass capsule that morphs
/// between segments through `glassEffectID`.
private struct PeriodPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Period.allCases) { period in
                    segment(period)
                }
            }
            .padding(3)
        }
        .background(Capsule().fill(Palette.hairline.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage period"))
    }

    private func segment(_ period: Period) -> some View {
        let isSelected = model.period == period
        return Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) {
                model.period = period
            }
        } label: {
            Text(period.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(HierarchicalShapeStyle.primary) : AnyShapeStyle(Palette.muted))
                .frame(minWidth: 30)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .contentShape(Capsule())
                // Glass applied to the label itself renders behind its text; as a background it covered the text.
                .modifier(SelectedGlass(isSelected: isSelected, namespace: selection))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SelectedGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("selection", in: namespace)
        } else {
            content
        }
    }
}
