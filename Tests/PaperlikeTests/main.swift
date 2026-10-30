import Darwin

let filters = Array(CommandLine.arguments.dropFirst())
let allTests = paperlikeFrameTests()
    + responseStreamDecoderTests()
    + connectionPresentationTests()
    + debouncedLightingCommandCoordinatorTests()
    + lightingCommandSessionStateTests()
    + nativeInterfaceContractTests()
    + serialConnectionTests()
    + serialDeviceMonitorTests()
    + paperlikeDeviceControllerTests()
    + appSettingsTests()
    + lightingAutomationSettingsTests()
    + lightingScheduleEngineTests()
    + lightingAutomationServiceTests()
    + displayDriverServiceTests()
    + autoRefreshServiceTests()
    + touchReportDecoderTests()
    + touchCoordinateMapperTests()
    + touchCalibrationWorkflowTests()
    + touchGestureInterpreterTests()
    + touchHIDServiceTests()
    + touchMappingServiceTests()
    + touchSettingsStoreTests()
    + touchUIStateTests()
    + configurationBackupTests()
    + nativeSettingsReliabilityTests()
let selectedTests = filters.isEmpty
    ? allTests
    : allTests.filter { test in
        filters.contains { test.name.localizedCaseInsensitiveContains($0) }
    }

guard !selectedTests.isEmpty else {
    print("No tests matched: \(filters.joined(separator: ", "))")
    print("Available tests:\n\(allTests.map(\.name).joined(separator: "\n"))")
    exit(EXIT_FAILURE)
}

var failures = 0
for test in selectedTests {
    do {
        try await test.body()
        print("✓ \(test.name)")
    } catch {
        failures += 1
        print("✗ \(test.name): \(error)")
    }
}

print("\(selectedTests.count) tests, \(failures) failures")
exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
