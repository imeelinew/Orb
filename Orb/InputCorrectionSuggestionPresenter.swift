import AppKit
import SwiftUI

final class InputCorrectionSuggestionPresenter {
    private var panel: NSPanel?

    @MainActor
    func show(suggestion: CorrectionSuggestion, near rect: CGRect?) {
        let panel = panel ?? makePanel()
        let hostingView = NSHostingView(rootView: InputCorrectionDiffView(suggestion: suggestion))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let size = hostingView.fittingSize
        let targetSize = CGSize(width: max(140, size.width), height: max(40, size.height))
        let origin = panelOrigin(for: rect, targetSize: targetSize)

        panel.setFrame(CGRect(origin: origin, size: targetSize), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func panelOrigin(for rect: CGRect?, targetSize: CGSize) -> CGPoint {
        guard let rect, let screen = NSScreen.main else {
            let mouseLocation = NSEvent.mouseLocation
            return CGPoint(
                x: min(max(mouseLocation.x, 8), (NSScreen.main?.frame.maxX ?? mouseLocation.x) - targetSize.width - 8),
                y: max(mouseLocation.y - targetSize.height - 8, 8)
            )
        }

        let screenFrame = screen.frame
        let topLeftY = rect.maxY + 8
        let originX = min(max(rect.minX, screenFrame.minX + 8), screenFrame.maxX - targetSize.width - 8)
        let originY = min(
            max(screenFrame.maxY - topLeftY - targetSize.height, screenFrame.minY + 8),
            screenFrame.maxY - targetSize.height - 8
        )
        return CGPoint(x: originX, y: originY)
    }

    @MainActor
    func dismiss() {
        panel?.orderOut(nil)
    }

    @MainActor
    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 160, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }
}

private struct InputCorrectionDiffView: View {
    let suggestion: CorrectionSuggestion

    var body: some View {
        HStack(spacing: 8) {
            Text("- \(suggestion.original)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.72, green: 0.10, blue: 0.12))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(red: 1.00, green: 0.86, blue: 0.86), in: RoundedRectangle(cornerRadius: 6))

            Text("+ \(suggestion.replacement)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 0.05, green: 0.46, blue: 0.20))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(red: 0.82, green: 0.96, blue: 0.86), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
