import PaperlikeLocalization
import AppKit
import PaperlikeCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            SettingsGroupBox(L("操作")) {
                HStack {
                    Button(L("重新连接")) { model.reconnect() }
                        .disabled(model.activeSerialPath == nil || model.isCommandRunning)
                        .centeredInSettingsList()
                    Button(L("复制诊断信息")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            diagnosticText,
                            forType: .string
                        )
                    }
                    .centeredInSettingsList()
                }
                .frame(maxWidth: .infinity)
                }

            SettingsGroupBox(L("连接")) {
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent(L("画面显示器"), value: model.displayConnected ? L("系统已识别") : L("未识别"))
                LabeledContent(L("控制连接"), value: model.connectionTitle)
                LabeledContent(L("触控设备"), value: model.touchIsTouchDeviceConnected ? L("已连接") : L("未连接或监听已暂停"))
                LabeledContent(L("触控授权"), value: model.touchIsAccessibilityTrusted ? L("已授权") : L("未授权"))
                LabeledContent(L("自动控制"), value: model.allControlsPaused ? L("全部暂停") : L("按各项设置运行"))
                LabeledContent(
                    L("串口"),
                    value: model.activeSerialPath ?? L("未发现")
                )
                LabeledContent(L("设备"), value: model.connectionDetail)
                }
            }

            SettingsGroupBox(L("最近执行记录")) {
                VStack(alignment: .leading, spacing: 8) {
                if model.recentOperations.isEmpty { Text(L("暂无记录")).foregroundStyle(.secondary) }
                ForEach(model.recentOperations) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(item.date, style: .time).foregroundStyle(.secondary)
                        }
                        Text(item.detail).font(.caption).foregroundStyle(item.failed ? .orange : .secondary)
                    }
                }
                }
            }

            SettingsGroupBox(L("协议")) {
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent(L("波特率"), value: "115200")
                LabeledContent(L("协议帧"), value: L("ASCII / 24 字节"))
                LabeledContent(
                    L("支持型号"),
                    value: L("PaperLike 13.3K 彩色版 / 黑白版")
                )
                if let profile = model.deviceState?.profile {
                    LabeledContent(L("面板"), value: profile.panelKind.displayText)
                    LabeledContent(
                        L("前光"),
                        value: profile.frontLightDisplayText
                    )
                    LabeledContent(
                        L("识别码"),
                        value: profile.identifierText
                    )
                    LabeledContent(
                        L("验证状态"),
                        value: profile.verificationText
                    )
                }
                }
            }
        }
    }

    private var diagnosticText: String {
        let profile = model.deviceState?.profile
        return L("""
        PaperLike Native
        版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("未知"))
        构建：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("未知"))
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        状态：\(model.connectionTitle)
        详情：\(model.connectionDetail)
        串口：\(model.activeSerialPath ?? L("未发现"))
        协议：115200 baud / 24-byte ASCII
        面板：\(profile?.panelKind.displayText ?? L("未知"))
        前光：\(profile?.frontLightDisplayText ?? L("未知"))
        识别码：\(profile?.identifierText ?? L("未知"))
        触控：\(model.touchUIState.statusText)
        坐标方案：\(model.touchCalibrationDescription)
        自动化：\(model.automationSummary)
        最近执行：
        \(model.recentOperations.map { "\($0.date.formatted()) \($0.title)：\($0.detail)" }.joined(separator: "\n"))
        """)
    }
}

private extension PaperlikeDeviceProfile {
    var identifierText: String {
        String(
            format: "MCU %02X / Family %02X",
            mcuVersion,
            familyIdentifier
        )
    }
}

#if DEBUG
struct DiagnosticsView_Previews: PreviewProvider {
    static var previews: some View {
        let model = AppModel()
        model.mockConnectedForPreview()
        return DiagnosticsView(model: model)
    }
}
#endif
