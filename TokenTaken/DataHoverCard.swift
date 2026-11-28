import AppKit
import SwiftUI

struct DataHoverCard<Content: View>: View {
    private let width: CGFloat
    private let showsSurface: Bool
    private let content: Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(width: CGFloat = 280, showsSurface: Bool = true, @ViewBuilder content: () -> Content) {
        self.width = width
        self.showsSurface = showsSurface
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        let card = content
            .padding(12)
            .frame(width: width, alignment: .leading)

        if showsSurface {
            card.tooltipSurface(reduceTransparency: reduceTransparency)
        } else {
            card
        }
    }
}

struct DataHoverPopover<Label: View, Content: View>: View {
    private let width: CGFloat
    private let arrowEdge: Edge
    private let label: Label
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var isPinned = false
    @State private var labelHovered = false
    @State private var popoverHovered = false
    @State private var hoverTask: Task<Void, Never>?

    init(
        width: CGFloat = 280,
        arrowEdge: Edge = .bottom,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.arrowEdge = arrowEdge
        self.label = label()
        self.content = content()
    }

    var body: some View {
        Button(action: togglePinned) {
            label
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            labelHovered = hovering
            updateHover()
        }
        .onExitCommand(perform: dismiss)
        .popover(isPresented: presentation, arrowEdge: arrowEdge) {
            DataHoverCard(width: width, showsSurface: false) {
                content
            }
            .modifier(DataHoverPopoverSurface())
            .contentShape(Rectangle())
            .onHover { hovering in
                popoverHovered = hovering
                updateHover()
            }
            .onExitCommand(perform: dismiss)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            dismiss()
        }
        .onDisappear(perform: dismiss)
        .transaction { transaction in
            transaction.disablesAnimations = reduceMotion
        }
    }

    private var presentation: Binding<Bool> {
        Binding {
            isPresented
        } set: { presented in
            if presented {
                isPresented = true
            } else {
                dismiss()
            }
        }
    }

    private func updateHover() {
        cancelHoverTask()

        let shouldPresent = labelHovered || popoverHovered
        if shouldPresent {
            isPresented = true
            return
        }
        guard isPresented, !isPinned else { return }

        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            hoverTask = nil
            guard !labelHovered, !popoverHovered, !isPinned else { return }
            isPresented = false
        }
    }

    private func togglePinned() {
        if isPresented, isPinned {
            dismiss()
        } else {
            cancelHoverTask()
            isPinned = true
            isPresented = true
        }
    }

    private func dismiss() {
        cancelHoverTask()
        labelHovered = false
        popoverHovered = false
        isPinned = false
        isPresented = false
    }

    private func cancelHoverTask() {
        hoverTask?.cancel()
        hoverTask = nil
    }
}

private struct DataHoverPopoverSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        switch ThemeKind.current {
        case .field, .cosmos:
            content.presentationBackground(Palette.cardSurface)
        case .liquidGlass:
            content
        }
    }
}
