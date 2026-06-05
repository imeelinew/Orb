import AppKit

enum StatusItemClickAction: Equatable {
    case primary
    case secondary
    case ignore
}

enum StatusItemClickHandling {
    static let actionEventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

    static func action(for eventType: NSEvent.EventType) -> StatusItemClickAction {
        switch eventType {
        case .leftMouseDown:
            return .primary
        case .rightMouseDown:
            return .secondary
        default:
            return .ignore
        }
    }
}
