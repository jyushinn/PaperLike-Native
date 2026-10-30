import PaperlikeLocalization
import PaperlikeTouch
import SwiftUI

@MainActor
private final class TouchCalibrationViewState: ObservableObject {
    @Published var workflow = TouchCalibrationWorkflow()
    @Published var resultMessage: String?
}

struct TouchCalibrationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = TouchCalibrationViewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L("校准"), systemImage: "scope")
                    .font(.title2.bold())
                Spacer()
                Text("\(state.workflow.points.count) / 4")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(L("单指轻触指定角落，点击“记录此点”。"))
                .foregroundStyle(.secondary)

            SettingsPanelGroupBox(L("当前触点")) {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(L("当前位置")) {
                        Text(nextCornerText)
                            .fontWeight(.semibold)
                    }
                    Divider()
                    Text(model.touchContactSummary)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let resultMessage = state.resultMessage {
                Label(resultMessage, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button(L("使用自动映射")) {
                    model.useAutomaticTouchCalibration()
                    dismiss()
                }
                Button(L("取消"), role: .cancel) {
                    state.workflow.reset()
                    model.cancelTouchCalibration()
                    dismiss()
                }
                Spacer()
                Button(L("记录此点")) {
                    captureCurrentPoint()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.touchLatestFrame == nil)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .onDisappear {
            model.cancelTouchCalibration()
        }
    }

    private var nextCornerText: String {
        switch state.workflow.nextCorner {
        case .topLeft:
            L("左上角")
        case .topRight:
            L("右上角")
        case .bottomRight:
            L("右下角")
        case .bottomLeft:
            L("左下角")
        case nil:
            L("已完成")
        }
    }

    private func captureCurrentPoint() {
        guard let frame = model.touchLatestFrame else {
            state.resultMessage = L("请先在目标位置轻触屏幕。")
            return
        }

        switch state.workflow.capture(frame) {
        case let .accepted(next):
            state.resultMessage = L("已记录，请继续轻触\(cornerText(next))。")
        case let .completed(calibration):
            model.saveTouchCalibration(calibration)
            dismiss()
        case let .rejected(error):
            switch error {
            case .singleContactRequired:
                state.resultMessage = L("请只保持一根手指触摸屏幕。")
            case .duplicatePoint:
                state.resultMessage = L("此点与已记录位置太近，请移到指定角。")
            case .invalidGeometry:
                state.resultMessage = L("四角位置异常，请重新记录当前角。")
            case .alreadyCompleted:
                state.resultMessage = L("校准已完成。")
            }
        }
    }

    private func cornerText(_ corner: TouchCalibrationCorner) -> String {
        switch corner {
        case .topLeft: L("左上角")
        case .topRight: L("右上角")
        case .bottomRight: L("右下角")
        case .bottomLeft: L("左下角")
        }
    }
}
