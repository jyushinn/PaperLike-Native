public struct ConnectionPresentation: Equatable, Sendable {
    public let symbolName: String
    public let menuBarIconName: String
    public let title: String
    public let accessibilityLabel: String
    public let showsProgress: Bool
    public let allowsReconnect: Bool
    private let detailText: String
    private let includesSerialPath: Bool

    public init(state: ConnectionState) {
        switch state {
        case let .connected(name, _):
            symbolName = "display"
            menuBarIconName = "PaperlikeMenuConnected"
            title = "已连接"
            accessibilityLabel = "显示器控制，已连接"
            showsProgress = false
            allowsReconnect = false
            detailText = name
            includesSerialPath = true
        case let .connecting(path):
            symbolName = "arrow.triangle.2.circlepath"
            menuBarIconName = "PaperlikeMenuConnecting"
            title = "正在连接…"
            accessibilityLabel = "显示器控制，正在连接"
            showsProgress = true
            allowsReconnect = false
            detailText = path
            includesSerialPath = false
        case .disconnected:
            symbolName = "display.trianglebadge.exclamationmark"
            menuBarIconName = "PaperlikeMenuDisconnected"
            title = "未连接"
            accessibilityLabel = "显示器控制，未连接"
            showsProgress = false
            allowsReconnect = false
            detailText = "请连接 PaperLike 13.3K 彩色版或黑白版"
            includesSerialPath = false
        case let .unsupported(identifier):
            symbolName = "exclamationmark.triangle"
            menuBarIconName = "PaperlikeMenuError"
            title = "连接异常"
            accessibilityLabel = "显示器控制，连接异常"
            showsProgress = false
            allowsReconnect = true
            detailText = identifier
            includesSerialPath = false
        case let .failed(message):
            symbolName = "exclamationmark.triangle"
            menuBarIconName = "PaperlikeMenuError"
            title = "连接异常"
            accessibilityLabel = "显示器控制，连接异常"
            showsProgress = false
            allowsReconnect = true
            detailText = message
            includesSerialPath = false
        }
    }

    public func detail(serialPath: String?) -> String {
        guard includesSerialPath, let serialPath else {
            return detailText
        }
        return "\(detailText)\n\(serialPath)"
    }
}
