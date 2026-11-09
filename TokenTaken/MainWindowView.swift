import SwiftUI
import TokenTakenKit

/// Two-column Condensation window: summary rail on the left, the condensation
/// field with source and model lists on the right.
struct MainWindowView: View {
    static let windowID = "main"

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TitleRow()
            PeriodBar()
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView {
                    SummaryRail(summary: model.summary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 22)
                }
                .scrollIndicators(.never)
                .frame(width: 284)

                Rectangle().fill(Palette.hairline).frame(width: 1)

                VStack(spacing: 16) {
                    CondensationView(summary: model.summary)
                        .frame(maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
                    BreakdownColumns(summary: model.summary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 18)
            }
        }
        .background { WindowBackdrop() }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// Sits in the hidden title bar band, level with the traffic lights.
private struct TitleRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "Token Taken")
                .font(.system(size: 13, weight: .semibold))
            Rectangle().fill(Palette.hairline).frame(width: 1, height: 12)
            Text("Condensation")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
        }
        // Leaves room for the traffic lights drawn over the content.
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .frame(height: 30)
        .padding(.top, 2)
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
                Text("Synthetic data · Not connected to collection yet")
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
