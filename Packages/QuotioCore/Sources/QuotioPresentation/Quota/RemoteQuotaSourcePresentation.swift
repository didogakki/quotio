import QuotioDomain
import SwiftUI

@MainActor
public extension RemoteQuotaSourceConnectionStatus {
    var displayText: String {
        switch self {
        case .unknown: "remote.quotaSource.status.unknown".localized()
        case .connecting: "remote.quotaSource.status.connecting".localized()
        case .connected: "remote.quotaSource.status.connected".localized()
        case .error(let key): key.localized()
        }
    }

    var color: Color {
        switch self {
        case .unknown: .gray
        case .connecting: .orange
        case .connected: .green
        case .error: .red
        }
    }

    var icon: String {
        switch self {
        case .unknown: "circle"
        case .connecting: "circle.dotted"
        case .connected: "checkmark.circle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }
}
