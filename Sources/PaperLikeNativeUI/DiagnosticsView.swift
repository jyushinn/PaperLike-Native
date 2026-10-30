import AppKit
import PaperlikeCore
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            SettingsGroupBox("操作") {
                HStack {
                    Button("重新连接") { model.reconnect() }
                        .disabled(model.activeSerialPath == nil || model.isCommandRunning)
                        .centeredInSettingsList()
                    Button("复制诊断信息") {
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

            SettingsGroupBox("连接") {
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent("画面显示器", value: model.displayConnected ? "系统已识别" : "未识别")
                LabeledContent("控制连接", value: model.connectionTitle)
                LabeledContent("触控设备", value: model.touchIsTouchDeviceConnected ? "已连接" : "未连接或监听已暂停")
                LabeledContent("触控授权", value: model.touchIsAccessibilityTrusted ? "已授权" : "未授权")
                LabeledContent("自动控制", value: model.allControlsPaused ? "全部暂停" : "按各项设置运行")
                LabeledContent(
                    "串口",
                    value: model.activeSerialPath ?? "未发现"
                )
                LabeledContent("设备", value: model.connectionDetail)
                }
            }

            SettingsGroupBox("最近执行记录") {
                VStack(alignment: .leading, spacing: 8) {
                if model.recentOperations.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
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

            SettingsGroupBox("协议") {
                VStack(alignment: .leading, spacing: 8) {
                LabeledContent("波特率", value: "115200")
                LabeledContent("协议帧", value: "ASCII / 24 字节")
                LabeledContent(
                    "支持型号",
                    value: "PaperLike 13.3K 彩色版 / 黑白版"
                )
                if let profile = model.deviceState?.profile {
                    LabeledContent("面板", value: profile.panelKind.displayText)
                    LabeledContent(
                        "前光",
                        value: profile.frontLightDisplayText
                    )
                    LabeledContent(
                        "识别码",
                        value: profile.identifierText
                    )
                    LabeledContent(
                        "验证状态",
                        value: profile.verificationText
                    )
                }
                }
            }
        }
    }

    private var diagnosticText: String {
        let profile = model.deviceState?.profile
        return """
        PaperLike Native
        版本：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")
        构建：\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)
        状态：\(model.connectionTitle)
        详情：\(model.connectionDetail)
        串口：\(model.activeSerialPath ?? "未发现")
        协议：115200 baud / 24-byte ASCII
        面板：\(profile?.panelKind.displayText ?? "未知")
        前光：\(profile?.frontLightDisplayText ?? "未知")
        识别码：\(profile?.identifierText ?? "未知")
        触控：\(model.touchUIState.statusText)
        坐标方案：\(model.touchCalibrationDescription)
        自动化：\(model.automationSummary)
        最近执行：
        \(model.recentOperations.map { "\($0.date.formatted()) \($0.title)：\($0.detail)" }.joined(separator: "\n"))
        """
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
