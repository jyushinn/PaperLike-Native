import PaperlikeLocalization
import ServiceManagement

/// Keep the system's approval state visible; reading it never changes registration.
enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .notRegistered: self = .notRegistered
        @unknown default: self = .notFound
        }
    }

    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var description: String {
        switch self {
        case .notRegistered: L("未启用；仅在你选择后注册登录项。")
        case .enabled: L("已启用登录时启动。")
        case .requiresApproval: L("等待批准，请在系统设置的登录项中允许 PaperLike Native。")
        case .notFound: L("系统未找到应用，请将应用放在应用程序目录后重试。")
        }
    }
}

@MainActor
final class LoginItemService {
    var status: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status == .notRegistered || status == .notFound { try SMAppService.mainApp.register() }
        } else if status.isRequested {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
