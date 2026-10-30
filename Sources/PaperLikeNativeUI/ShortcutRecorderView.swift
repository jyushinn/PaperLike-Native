import AppKit
import Carbon
import PaperlikeCore
import SwiftUI

struct ShortcutRecorderView: View {
    let title: String
    let definition: Binding<HotKeyDefinition?>

    var body: some View {
        LabeledContent(title) {
            HStack {
                ShortcutCaptureButton(definition: definition)
                    .frame(width: 130)
                if definition.wrappedValue != nil {
                    Button {
                        definition.wrappedValue = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("清除")
                }
            }
        }
    }
}

private struct ShortcutCaptureButton: NSViewRepresentable {
    let definition: Binding<HotKeyDefinition?>

    func makeCoordinator() -> Coordinator {
        Coordinator(definition: definition)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            title: context.coordinator.displayText,
            target: context.coordinator,
            action: #selector(Coordinator.beginRecording)
        )
        button.bezelStyle = .rounded
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.definition = definition
        if !context.coordinator.isRecording {
            button.title = context.coordinator.displayText
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var definition: Binding<HotKeyDefinition?>
        weak var button: NSButton?
        var monitor: Any?
        var isRecording = false

        init(definition: Binding<HotKeyDefinition?>) {
            self.definition = definition
        }

        isolated deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        var displayText: String {
            guard let definition = definition.wrappedValue else {
                return "未设置"
            }
            var parts: [String] = []
            if definition.modifiers & UInt32(controlKey) != 0 {
                parts.append("⌃")
            }
            if definition.modifiers & UInt32(optionKey) != 0 {
                parts.append("⌥")
            }
            if definition.modifiers & UInt32(shiftKey) != 0 {
                parts.append("⇧")
            }
            if definition.modifiers & UInt32(cmdKey) != 0 {
                parts.append("⌘")
            }
            parts.append(Self.keyName(definition.keyCode))
            return parts.joined()
        }

        @objc func beginRecording() {
            stopRecording()
            isRecording = true
            button?.title = "请按快捷键…"
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 {
                    stopRecording()
                    return nil
                }

                var modifiers: UInt32 = 0
                if event.modifierFlags.contains(.control) {
                    modifiers |= UInt32(controlKey)
                }
                if event.modifierFlags.contains(.option) {
                    modifiers |= UInt32(optionKey)
                }
                if event.modifierFlags.contains(.shift) {
                    modifiers |= UInt32(shiftKey)
                }
                if event.modifierFlags.contains(.command) {
                    modifiers |= UInt32(cmdKey)
                }
                guard modifiers != 0 else {
                    return nil
                }

                definition.wrappedValue = HotKeyDefinition(
                    keyCode: UInt32(event.keyCode),
                    modifiers: modifiers
                )
                stopRecording()
                return nil
            }
        }

        private func stopRecording() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            isRecording = false
            button?.title = displayText
        }

        private static func keyName(_ code: UInt32) -> String {
            [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
                6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
                13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
                31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
                38: "J", 40: "K", 45: "N", 46: "M",
                24: "+", 27: "−"
            ][code] ?? "键\(code)"
        }
    }
}

struct ShortcutRecorderView_Previews: PreviewProvider {
    static var previews: some View {
        ShortcutRecorderView(title: "切换显示模式", definition: .constant(nil))
    }
}
