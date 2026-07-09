import Foundation

enum PermissionState {
    case ok
    case fail
    case info   // informational / optional, not a hard failure
}

struct PermissionItem {
    let name: String
    let state: PermissionState
    let detail: String
}

/// Renders the permission checklist as the NSAlert informativeText.
/// Pure and deterministic so it can be unit-tested without the AppKit/TCC APIs.
func permissionReportText(_ items: [PermissionItem]) -> String {
    return items.map { item -> String in
        let symbol: String
        switch item.state {
        case .ok:   symbol = "✅"
        case .fail: symbol = "❌"
        case .info: symbol = "ℹ️"
        }
        let detail = item.detail.isEmpty ? "" : "\n    \(item.detail)"
        return "\(symbol) \(item.name)\(detail)"
    }.joined(separator: "\n\n")
}

/// True if any item is a hard failure (drives whether we offer the Settings button).
func hasPermissionFailure(_ items: [PermissionItem]) -> Bool {
    return items.contains { $0.state == .fail }
}
