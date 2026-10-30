public enum PaperlikePanelKind: Equatable, Sendable {
    case color
    case monochrome

    public var displayText: String {
        switch self {
        case .color:
            "彩色"
        case .monochrome:
            "黑白"
        }
    }
}

public struct PaperlikeDeviceProfile: Equatable, Sendable {
    public let mcuVersion: UInt8
    public let familyIdentifier: UInt8
    public let panelKind: PaperlikePanelKind

    public init?(
        mcuVersion: UInt8,
        familyIdentifier: UInt8
    ) {
        guard [0x10, 0x11, 0x30, 0x31].contains(mcuVersion) else {
            return nil
        }
        let panelKind: PaperlikePanelKind
        switch familyIdentifier {
        case 0x01:
            panelKind = .color
        case 0x02:
            panelKind = .monochrome
        default:
            return nil
        }
        self.mcuVersion = mcuVersion
        self.familyIdentifier = familyIdentifier
        self.panelKind = panelKind
    }

    public var hasFrontLight: Bool {
        mcuVersion & 0xFE == 0x30
    }

    public var displayName: String {
        let panel = panelKind == .color ? "彩色版" : "黑白版"
        let light = hasFrontLight ? "有前光" : "无前光"
        return "PaperLike 13.3K \(panel)（\(light)）"
    }

    public var frontLightDisplayText: String {
        hasFrontLight ? "支持" : "不支持"
    }

    public var verificationText: String {
        mcuVersion == 0x30 && familyIdentifier == 0x01
            ? "已在此识别码的彩色版实机验证"
            : "协议兼容，未实机验证"
    }
}
