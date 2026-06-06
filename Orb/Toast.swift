import SwiftUI

enum OrbUI {
    enum Toast {
        static let font: Font = .system(size: 13, weight: .regular)
        static let horizontalPadding: CGFloat = 16
        static let verticalPadding: CGFloat = 11
        static let topOffset: CGFloat = 12
        static let duration: Duration = .seconds(2)
        static let shadowColor: Color = .black.opacity(0.16)
        static let shadowRadius: CGFloat = 18
        static let shadowY: CGFloat = 8

        static let showAnimation: Animation = .spring(duration: 0.24, bounce: 0.18)
        static let hideAnimation: Animation = .easeOut(duration: 0.18)

        static let errorColor = Color(red: 0.82, green: 0.18, blue: 0.18)
    }
}

struct AppToast: Equatable, Identifiable {
    enum Kind: Equatable, Sendable {
        case success
        case error
    }

    let id = UUID()
    let message: String
    let kind: Kind

    init(message: String, kind: Kind = .success) {
        self.message = message
        self.kind = kind
    }

    var systemImage: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var foregroundStyle: Color {
        switch kind {
        case .success: return .primary
        case .error: return OrbUI.Toast.errorColor
        }
    }
}

struct ToastViewModifier: ViewModifier {
    @Binding var toast: AppToast?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    toastLabel(for: toast)
                        .padding(.top, OrbUI.Toast.topOffset)
                        .transition(.blurReplace.animation(OrbUI.Toast.showAnimation))
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .task(id: toast) {
                guard let currentToast = toast else { return }
                try? await Task.sleep(for: OrbUI.Toast.duration)
                await MainActor.run {
                    guard toast == currentToast else { return }
                    withAnimation(OrbUI.Toast.hideAnimation) {
                        toast = nil
                    }
                }
            }
    }

    @ViewBuilder
    private func toastLabel(for toast: AppToast) -> some View {
        let base = Label(toast.message, systemImage: toast.systemImage)
            .font(OrbUI.Toast.font)
            .foregroundStyle(toast.foregroundStyle)
            .padding(.horizontal, OrbUI.Toast.horizontalPadding)
            .padding(.vertical, OrbUI.Toast.verticalPadding)
            .shadow(
                color: OrbUI.Toast.shadowColor,
                radius: OrbUI.Toast.shadowRadius,
                y: OrbUI.Toast.shadowY
            )

        if #available(macOS 26.0, *) {
            base
                .glassEffect(.regular, in: Capsule())
        } else {
            base
                .background(.regularMaterial, in: Capsule())
        }
    }
}

extension View {
    func toast(_ toast: Binding<AppToast?>) -> some View {
        modifier(ToastViewModifier(toast: toast))
    }
}
