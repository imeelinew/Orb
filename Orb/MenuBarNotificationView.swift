import SwiftUI

@MainActor
struct MenuBarNotificationView: View {
    let title: String
    let subtitle: String
    let actionID: String
    let kind: Kind
    let progress: ProgressState?

    enum Kind {
        case success
        case error
    }

    struct ProgressState: Equatable {
        let fraction: Double
        let remainingText: String
    }

    init(
        title: String,
        subtitle: String,
        actionID: String,
        kind: Kind,
        progress: ProgressState? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionID = actionID
        self.kind = kind
        self.progress = progress
    }

    private var iconAssetName: String? {
        switch actionID {
        case "new-markdown":
            return "logo-markdown"
        case "open-ghostty":
            return "logo-ghostty"
        case "open-vscode":
            return "logo-vscode"
        case "git-commit-push":
            return "logo-github"
        default:
            return nil
        }
    }

    private var iconName: String {
        switch actionID {
        case "subtitles":
            return "captions.bubble"
        case "new-text":
            return "doc.text"
        case "new-markdown":
            return "chevron.left.forwardslash.chevron.right"
        case "new-word":
            return "doc.richtext"
        case "open-ghostty":
            return "terminal"
        case "open-vscode":
            return "curlybraces"
        case "git-commit-push":
            return "arrow.up.doc"
        case "copy-path":
            return "point.topleft.down.curvedto.point.bottomright.up"
        default:
            return "checkmark"
        }
    }

    private var iconGradient: LinearGradient {
        if kind == .error {
            return LinearGradient(
                colors: [
                    Color(red: 0.94, green: 0.27, blue: 0.22),
                    Color(red: 0.82, green: 0.18, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        switch actionID {
        case "new-text":
            return LinearGradient(
                colors: [
                    Color(red: 0.48, green: 0.58, blue: 0.70),
                    Color(red: 0.25, green: 0.34, blue: 0.48)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "new-markdown":
            return LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.22, blue: 0.26),
                    Color(red: 0.05, green: 0.06, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "new-word":
            return LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.46, blue: 0.96),
                    Color(red: 0.07, green: 0.22, blue: 0.68)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "open-ghostty":
            return LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.26, blue: 0.34),
                    Color(red: 0.10, green: 0.10, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "open-vscode":
            return LinearGradient(
                colors: [
                    Color(red: 0.15, green: 0.55, blue: 0.92),
                    Color(red: 0.00, green: 0.32, blue: 0.67)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "git-commit-push":
            return LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.42, blue: 0.22),
                    Color(red: 0.76, green: 0.18, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "copy-path":
            return LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.50, blue: 0.36),
                    Color(red: 0.83, green: 0.22, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [
                    Color(red: 0.18, green: 0.78, blue: 0.35),
                    Color(red: 0.12, green: 0.64, blue: 0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let iconAssetName {
            Image(iconAssetName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(assetIconPadding)
        } else {
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }

    private var assetIconPadding: CGFloat {
        switch actionID {
        case "logo-markdown":
            return 6
        case "new-markdown":
            return 6
        case "open-vscode":
            return 7
        case "git-commit-push":
            return 6
        default:
            return 7
        }
    }

    private var clampedProgress: CGFloat {
        CGFloat(min(max(progress?.fraction ?? 0, 0), 1))
    }

    var body: some View {
        if let progress {
            progressBody(progress)
        } else {
            notificationBody
        }
    }

    private var notificationBody: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconGradient)

                iconView
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
    }

    private func progressBody(_ progress: ProgressState) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(iconGradient)

                iconView
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    Text(verbatim: progress.remainingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }

                if !subtitle.isEmpty {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.16))

                        Capsule()
                            .fill(Color(red: 0.18, green: 0.78, blue: 0.35))
                            .frame(width: max(6, proxy.size.width * clampedProgress))
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280, alignment: .leading)
    }
}
