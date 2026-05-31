import SwiftUI

private let clipboardPanelCornerRadius: CGFloat = 22

/// 剪贴板浮层外壳：macOS 26 Liquid Glass（加强可见度，非 Material）。
struct ClipboardPanelChromeView: View {
    var body: some View {
        GlassEffectContainer {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(
                    .regular
                        .tint(.white.opacity(0.42))
                        .interactive(),
                    in: .rect(cornerRadius: clipboardPanelCornerRadius)
                )
        }
        .compositingGroup()
        .clipShape(
            RoundedRectangle(cornerRadius: clipboardPanelCornerRadius, style: .continuous)
        )
    }
}

enum ClipboardPanelMetrics {
    static let cornerRadius: CGFloat = clipboardPanelCornerRadius
}
