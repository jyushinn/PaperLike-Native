import Darwin
import Foundation
import PaperlikeCore
import PaperlikeProtocol
import SerialTransport

@MainActor
func performHardwareRoundTrip(
    apply: @MainActor () async throws -> Void,
    restore: @MainActor () async throws -> Void
) async throws {
    do {
        try await apply()
        try await restore()
    } catch {
        let operationError = error
        do { try await restore() }
        catch {
            throw NSError(domain: "PaperlikeProbe", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "自测失败：\(operationError.localizedDescription) 原值恢复也失败：\(error.localizedDescription)"
            ])
        }
        throw operationError
    }
}

guard CommandLine.arguments.count >= 2 else {
    print("用法：PaperlikeProbe /dev/cu.usbserial-设备")
    exit(EXIT_FAILURE)
}

let controller = PaperlikeDeviceController()
do {
    if CommandLine.arguments.contains("--raw") {
        let serial = POSIXSerialConnection(path: CommandLine.arguments[1])
        try await serial.open()
        var iterator = serial.incomingBytes.makeAsyncIterator()
        try await serial.write(
            try PaperlikeRequest(command: .query, parameter: 0x10).encoded()
        )
        if let bytes = try await iterator.next() {
            print("ASCII：\(String(decoding: bytes, as: UTF8.self))")
            print("HEX：\(bytes.map { String(format: "%02X", $0) }.joined())")
        }
        await serial.close()
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.contains("--driver-self-test") || CommandLine.arguments.contains("--dither-self-test") {
        let driver = DisplayDriverService()
        let includeEnhancement = CommandLine.arguments.contains("--driver-self-test")
        do {
            try driver.setDitheringEnabled(true)
            if includeEnhancement { try driver.setEnhancementEnabled(true) }
            try driver.restore()
        } catch {
            let operationError = error
            do { try driver.restore() }
            catch {
                throw NSError(domain: "PaperlikeProbe", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "自测失败：\(operationError.localizedDescription) 原值恢复也失败：\(error.localizedDescription)"
                ])
            }
            throw operationError
        }
        print(includeEnhancement ? "✓ 显示驱动属性写入与恢复" : "✓ 抖动属性写入与恢复")
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.contains("--restore-baseline") {
        throw NSError(domain: "PaperlikeProbe", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "恢复需要真实原值；此选项没有提供原值，不会写入固定参数。请使用自测的自动恢复。"
        ])
    }
    try await controller.connect(path: CommandLine.arguments[1])
    let initial = await controller.currentState()
    print(initial)

    if CommandLine.arguments.contains("--self-test"),
       case let .connected(_, state) = initial {
        let alternateMode: DisplayMode = state.mode == .web ? .image : .web
        print("… 显示模式")
        try await performHardwareRoundTrip(
            apply: { try await controller.setMode(alternateMode) },
            restore: { try await controller.setMode(state.mode) }
        )
        print("✓ 显示模式")

        let alternateThreshold = state.threshold == 1 ? 2 : 1
        print("… 对比度")
        try await performHardwareRoundTrip(
            apply: { try await controller.setThreshold(alternateThreshold) },
            restore: { try await controller.setThreshold(state.threshold) }
        )
        print("✓ 对比度")

        if let speedTest = HardwareSelfTestPlan.speedRoundTrip(
            from: state.speed
        ) {
            print("… 刷新速度")
            try await performHardwareRoundTrip(
                apply: { try await controller.setSpeed(speedTest.alternate) },
                restore: { try await controller.setSpeed(speedTest.restore) }
            )
            print("✓ 刷新速度")
        } else {
            print("↷ 刷新速度无法读回，为避免改变原设置已跳过")
        }

        if state.frontLightAvailable {
            let alternateLightMode = state.frontLightMode == 0 ? 3 : 0
            print("… 前光模式")
            try await performHardwareRoundTrip(
                apply: { try await controller.setFrontLightMode(alternateLightMode) },
                restore: { try await controller.setFrontLightMode(state.frontLightMode) }
            )
            print("✓ 前光模式")

            let alternateBrightness = state.brightness == 100
                ? state.brightness - 1
                : state.brightness + 1
            print("… 前光亮度")
            try await performHardwareRoundTrip(
                apply: { try await controller.setBrightness(alternateBrightness) },
                restore: { try await controller.setBrightness(state.brightness) }
            )
            print("✓ 前光亮度")

            let alternateTemperature = state.temperature == 100
                ? state.temperature - 1
                : state.temperature + 1
            print("… 前光色温")
            try await performHardwareRoundTrip(
                apply: { try await controller.setTemperature(alternateTemperature) },
                restore: { try await controller.setTemperature(state.temperature) }
            )
            print("✓ 前光色温")
        } else {
            print("↷ 当前型号无前光，已跳过前光模式、亮度和色温")
        }

        print("… 快速刷新")
        try await controller.refresh()
        print("✓ 快速刷新")
    }
    await controller.disconnect()
} catch {
    await controller.disconnect()
    print("探测失败：\(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
