import Foundation

func nativeInterfaceContractTests() -> [TestCase] {
    [
        TestCase("NativeInterfaceContract.keepsHIGControlsNamedAndReplacementCautious") {
            let settings = try source("SettingsView.swift")
            let panel = try source("QuickPanelView.swift")
            let configuration = try source("ConfigurationSettingsView.swift")
            try expect(settings.contains(".accessibilityElement(children: .contain)"), "group controls remain independently discoverable")
            try expect(panel.contains(".accessibilityLabel(L(\"打开设置\"))") && panel.contains(".accessibilityLabel(L(\"退出 PaperLike Native\"))"), "icon-only buttons have action names")
            try expect(configuration.contains("Button(L(\"替换配置\"), role: .destructive)") && configuration.contains(".keyboardShortcut(.cancelAction)"), "replacement is explicit and Escape can cancel")
        },
        TestCase("NativeInterfaceContract.deliversCalendarNotificationsOnMainQueue") {
            let model = try source("AppModel.swift")
            guard let start = model.range(of: "let timeNotifications ="),
                  let end = model.range(of: ".store(in: &cancellables)", range: start.upperBound..<model.endIndex) else {
                throw TestFailure(description: "calendar observer exists")
            }
            let observer = String(model[start.lowerBound..<end.upperBound])
            try expect(observer.contains(".receive(on: DispatchQueue.main)\n        .sink"),
                       "midnight notifications must hop to the main queue before entering an actor-isolated sink")
        },
        TestCase("NativeInterfaceContract.keepsEssentialLayout") {
            let quickPanel = try source("QuickPanelView.swift")
            let settings = try source("SettingsView.swift")
            let model = try source("AppModel.swift")
            try expect(
                quickPanel.contains(".lineLimit(2)"),
                "connection detail allows the device name and path"
            )
            try expect(
                settings.contains("NavigationSplitView"),
                "settings uses a native sidebar"
            )
            try expect(
                settings.contains(".navigationSplitViewColumnWidth(min:")
                    && settings.contains("SettingsWindowLayout.previewSize")
                    && settings.contains("SettingsWindowLayout.minimumSize")
                    && !settings.contains(".frame(width: SettingsWindowLayout.sidebarWidth)")
                    && settings.contains("case .automation, .configurations: L(\"场景\")")
                    && model.contains("SettingsWindowLayout.initialSize")
                    && model.contains("SettingsWindowLayout.minimumSize"),
                "settings window and preview share sizing constraints"
            )
        },
        TestCase("NativeInterfaceContract.pairsVerticalSlidersSideBySideWithoutPauseAction") {
            let quickPanel = try source("QuickPanelView.swift")
            guard let sliderStart = quickPanel.range(of: "private func valueSlider(") else {
                throw TestFailure(description: "value slider helper exists")
            }
            let slider = quickPanel[sliderStart.lowerBound...]
            try expect(!quickPanel.contains("setAllControlsPaused"), "quick panel omits pause automation action")
            try expect(slider.contains("return VStack(alignment: .leading, spacing: 5)"),
                       "each slider keeps its label above the track")
            try expect(quickPanel.components(separatedBy: "HStack(alignment: .top, spacing: 12)").count == 3,
                       "brightness/temperature and contrast/speed use side-by-side pairs")
        },
        TestCase("NativeInterfaceContract.usesGroupBoxSectionTitles") {
            let quickPanel = try source("QuickPanelView.swift")
            let settings = try source("SettingsView.swift")
            try expect(quickPanel.contains("SettingsPanelGroupBox(title)"), "quick panel retains its floating card style")
            try expect(settings.contains("Section {"), "settings use native grouped list sections")
        },
        TestCase("NativeInterfaceContract.previewsQuickPanelWithTouch") {
            let quickPanel = try source("QuickPanelView.swift")
            try expect(quickPanel.contains("preview(touch: true)"), "canvas exposes a touch-enabled quick panel preview")
            try expect(quickPanel.contains("previewDisplayName(L(\"含触控\"))"), "touch preview is named in the canvas selector")
        },
        TestCase("NativeInterfaceContract.previewsTouchAccessibilityRequired") {
            let quickPanel = try source("QuickPanelView.swift")
            try expect(quickPanel.contains("preview(needsAccessibility: true)"), "canvas exposes the authorization-required state")
            try expect(quickPanel.contains("previewDisplayName(L(\"需辅助功能授权\"))"), "authorization preview is named in the canvas selector")
        },
        TestCase("NativeInterfaceContract.spreadsTouchControlsAcrossPanelWidth") {
            let quickPanel = try source("QuickPanelView.swift")
            guard let touchStart = quickPanel.range(of: "panelSection(L(\"触控\"))"),
                  let helperStart = quickPanel.range(of: "private func panelSection", range: touchStart.upperBound..<quickPanel.endIndex) else {
                throw TestFailure(description: "touch panel section exists")
            }
            let touchSection = quickPanel[touchStart.lowerBound..<helperStart.lowerBound]
            try expect(touchSection.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
                       "touch section content fills the panel width")
            try expect(touchSection.contains("HStack(spacing: 8)"), "touch actions share a full-width row")
        },
        TestCase("NativeInterfaceContract.keepsSettingsToolbarTitleStable") {
            let settings = try source("SettingsView.swift")
            let appModel = try source("AppModel.swift")
            try expect(
                !settings.contains(".navigationTitle(L(\"设置\"))")
                    && appModel.contains(".fullSizeContentView")
                    && appModel.contains("window.titleVisibility = .hidden")
                    && appModel.contains("window.titlebarAppearsTransparent = true"),
                "settings hides title text while retaining native window controls"
            )
        },
        TestCase("NativeInterfaceContract.usesGroupedFullWidthSettingsLists") {
            let settings = try source("SettingsView.swift")
            let quickPanel = try source("QuickPanelView.swift")
            let ruleEditor = try source("ScheduleRuleEditorView.swift")
            try expect(settings.contains("Text(title).padding(4)"), "settings section titles retain 4-point insets")
            try expect(settings.contains(".padding(4)") && settings.contains("VStack(alignment: .leading, spacing: 4) { content }"), "settings groups use vertical content with 4-point insets")
            try expect(settings.contains("List { content }") && settings.contains(".listStyle(.inset)"), "settings use native grouped lists")
            try expect(settings.contains("EdgeInsets(top: 12, leading: 4, bottom: 12, trailing: 4)"), "settings groups use 24-point vertical spacing")
            try expect(settings.contains(".frame(maxWidth: .infinity"), "settings list fills the available width")
            try expect(quickPanel.contains("SettingsPanelGroupBox(title)") && !quickPanel.contains("EdgeInsets(top: 12"), "floating panel spacing remains unchanged")
            try expect(ruleEditor.contains(".formStyle(.grouped)") && !ruleEditor.contains("SettingsList {"), "automation editor uses a native form independent of settings-page spacing")
            try expect(ruleEditor.contains(".toggleStyle(.button)") && ruleEditor.contains("LabeledContent(title)"), "weekday selections and slider columns use native control semantics")
            try expect(!ruleEditor.contains("step: 1"), "rule editor sliders avoid dense tick marks")
        },
        TestCase("NativeInterfaceContract.usesSwitchesInSettingsLists") {
            let settings = try source("SettingsView.swift")
            guard let listStart = settings.range(of: "struct SettingsList<"),
                  let listEnd = settings.range(of: "extension View", range: listStart.upperBound..<settings.endIndex) else {
                throw TestFailure(description: "shared settings list exists")
            }
            let list = settings[listStart.lowerBound..<listEnd.lowerBound]
            try expect(list.contains(".toggleStyle(.switch)"), "settings toggles use standard switches rather than checkboxes")
        },
        TestCase("NativeInterfaceContract.usesSystemSettingsCardsAndTwoColumnShortcuts") {
            let settings = try source("SettingsView.swift")
            try expect(settings.contains("GroupBox(label: Text(title).padding(4))"), "settings sections render as native cards")
            try expect(settings.contains(".listRowBackground(Color.clear)"), "list rows do not cover the group card")
            try expect(settings.contains("shortcuts(columns: [GridItem(.flexible()), GridItem(.flexible())])")
                && settings.contains("ViewThatFits(in: .horizontal)"), "global shortcuts use equal columns and adapt to narrow windows")
        },
        TestCase("NativeInterfaceContract.movesRefreshControlsIntoQuickPanel") {
            let settings = try source("SettingsView.swift")
            let quickPanel = try source("QuickPanelView.swift")
            try expect(!settings.contains("自动清残影"), "automatic refresh is not configured in settings")
            try expect(quickPanel.contains("Stepper(") && quickPanel.contains("autoRefreshIntervalSeconds"), "quick panel exposes automatic refresh interval")
        },
        TestCase("NativeInterfaceContract.groupsAutomationAndDiagnosticsUnderAbout") {
            let settings = try source("SettingsView.swift")
            let automation = try source("AutomationSettingsView.swift")
            let diagnostics = try source("DiagnosticsView.swift")
            try expect(settings.contains("case .automation, .configurations: L(\"场景\")"), "sidebar calls the combined destination scenes")
            try expect(settings.contains("case .automation, .configurations:"), "legacy scene destination routes into automation")
            try expect(automation.contains("ConfigurationSettingsView(model: model)"), "scene and backup groups appear under automation")
            try expect(settings.contains("DiagnosticsView(model: model)"), "connection and records appear under about")
            guard let sidebarStart = settings.range(of: "static var sidebarItems"),
                  let sidebarEnd = settings.range(of: "public var id", range: sidebarStart.upperBound..<settings.endIndex) else {
                throw TestFailure(description: "settings sidebar destinations exist")
            }
            let sidebar = settings[sidebarStart.lowerBound..<sidebarEnd.lowerBound]
            try expect(!sidebar.contains(".diagnostics") && !sidebar.contains(".configurations"), "connection and records are removed from sidebar")
            try expect(diagnostics.contains("SettingsGroupBox(L(\"连接\"))") && diagnostics.contains("最近执行记录"), "diagnostics retains connection and records")
        },
        TestCase("NativeInterfaceContract.refreshesAccessibilityOnActivationAndReportsAutomationErrors") {
            let settings = try source("SettingsView.swift")
            let model = try source("AppModel.swift")
            try expect(settings.contains("NSApplication.didBecomeActiveNotification"), "touch permission refreshes when returning from System Settings")
            try expect(model.contains("errorMessage = L(\"无法修改系统辅助功能设置"), "system accessibility toggle reports permission or scripting failure")
        },
        TestCase("NativeInterfaceContract.alwaysShowsTwoSettingsColumns") {
            let settings = try source("SettingsView.swift")
            try expect(
                settings.contains("NavigationSplitView(columnVisibility: .constant(.all))")
                    && settings.contains(".toolbar(removing: .sidebarToggle)"),
                "settings keeps the sidebar visible without a toggle button"
            )
        },
        TestCase("NativeInterfaceContract.ordersLabBeforeTouchAndRemovesTitlebarDivider") {
            let settings = try source("SettingsView.swift")
            let model = try source("AppModel.swift")
            try expect(settings.contains("[.general, .appAdaptation, .automation, .experiments, .about]"), "touch is nested under the lab instead of the sidebar")
            try expect(model.contains("window.titlebarSeparatorStyle = .none"), "settings window hides the titlebar separator")
        },
        TestCase("NativeInterfaceContract.centersSettingsListActions") {
            let settings = try source("SettingsView.swift")
            let touch = try source("TouchSettingsView.swift")
            let automation = try source("AutomationSettingsView.swift")
            let configuration = try source("ConfigurationSettingsView.swift")
            let diagnostics = try source("DiagnosticsView.swift")
            let experiments = try source("ExperimentalFeaturesView.swift")
            try expect(settings.contains("func centeredInSettingsList()"), "settings list exposes a centered action modifier")
            try expect(touch.contains(".centeredInSettingsList()"), "touch settings actions are centered")
            try expect(automation.contains(".centeredInSettingsList()"), "automation settings actions are centered")
            try expect(configuration.contains(".centeredInSettingsList()"), "scene and backup actions are centered")
            try expect(diagnostics.contains(".centeredInSettingsList()"), "diagnostic actions are centered")
            try expect(experiments.contains(".centeredInSettingsList()"), "lab actions are centered")
        },
        TestCase("NativeInterfaceContract.embedsTouchInLabAndKeepsActionsOnRows") {
            let settings = try source("SettingsView.swift")
            let experiments = try source("ExperimentalFeaturesView.swift")
            let touch = try source("TouchSettingsView.swift")
            guard let sidebarStart = settings.range(of: "static var sidebarItems"),
                  let sidebarEnd = settings.range(of: "public var id", range: sidebarStart.upperBound..<settings.endIndex) else {
                throw TestFailure(description: "settings sidebar destinations exist")
            }
            let sidebar = settings[sidebarStart.lowerBound..<sidebarEnd.lowerBound]
            try expect(!sidebar.contains(".touch"), "touch is not a separate sidebar item")
            try expect(settings.contains("case .touch, .experiments:"), "legacy touch route opens the lab")
            try expect(experiments.contains("TouchSettingsView(model: model)"), "touch controls are embedded in the lab")
            try expect(touch.contains("HStack(spacing: 8)"), "touch action buttons share a horizontal row")
            try expect(touch.contains("Button(L(\"使用自动映射\"))") && touch.contains("Button(L(\"四角校准\"))"), "calibration actions remain together")
        },
        TestCase("NativeInterfaceContract.exposesNativeTouchControls") {
            let experiments = try source("TouchSettingsView.swift")
            let calibration = try source("TouchCalibrationView.swift")
            let quickPanel = try source("QuickPanelView.swift")

            for label in ["触控映射", "请求辅助功能权限", "测试触点", "使用自动映射"] {
                try expect(
                    experiments.contains(label),
                    "normal touch settings contains \(label)"
                )
            }
            try expect(calibration.contains("校准"), "calibration sheet contains 校准")
            try expect(quickPanel.contains("暂停触控"), "quick panel contains 暂停触控")
        },
        TestCase("NativeInterfaceContract.linksTouchModule") {
            let package = try repositorySource("Package.swift")
            try expect(
                package.contains("dependencies: [\"PaperlikeCore\", \"SerialTransport\", \"PaperlikeTouch\", \"PaperlikeLocalization\"]"),
                "PaperLikeNativeUI depends on PaperlikeTouch"
            )
        },
        TestCase("NativeInterfaceContract.shutsTouchDownBeforeTermination") {
            let app = try repositorySource("Sources/PaperLikeNative/PaperLikeNativeApp.swift")
            let model = try source("AppModel.swift")
            try expect(
                app.contains("applicationWillTerminate") && app.contains("model.shutdown()"),
                "AppDelegate.applicationWillTerminate calls AppModel touch shutdown path"
            )
            guard let shutdownStart = model.range(of: "public func shutdown()") else {
                throw TestFailure(description: "AppModel exposes shutdown")
            }
            let shutdownSource = model[shutdownStart.lowerBound...]
            try expect(
                shutdownSource.contains("touchMapping.shutdown()")
                    && shutdownSource.contains("displayDriver.restore()"),
                "AppModel shutdown releases touch and restores the display driver"
            )
        },
        TestCase("NativeInterfaceContract.keepsMenuBarStatusObservable") {
            let app = try repositorySource("Sources/PaperLikeNative/PaperLikeNativeApp.swift")
            try expect(
                app.contains("struct MenuBarStatusLabel")
                    && app.contains("@ObservedObject var model: AppModel"),
                "menu bar status continues observing the delegate-owned model"
            )
        },
        TestCase("NativeInterfaceContract.usesBrandMenuIcons") {
            let app = try repositorySource("Sources/PaperLikeNative/PaperLikeNativeApp.swift")
            let quickPanel = try source("QuickPanelView.swift")
            let build = try repositorySource("Tools/build-app.sh")
            try expect(
                app.contains("ConnectionStatusIcon(presentation: model.connectionPresentation"),
                "menu bar uses the shared resource-backed icon view"
            )
            try expect(
                quickPanel.contains("ConnectionStatusIcon(presentation: presentation"),
                "quick panel repeats the same connection artwork"
            )
            let icon = try source("ConnectionStatusIcon.swift")
            try expect(
                icon.contains("PaperLikeArtwork.statusIcon(named:")
                    && icon.contains("Bundle.main.image(forResource:")
                    && icon.contains("Resources/MenuBarIcons")
                    && icon.contains("Image(nsImage: image)")
                    && icon.contains("Image(systemName: presentation.symbolName)"),
                "branded status icons load in packaged apps and local previews"
            )
            try expect(
                build.contains("Resources/MenuBarIcons")
                    && build.contains("sips -s format png"),
                "app build renders the editable menu bar SVG files"
            )
        },
        TestCase("NativeInterfaceContract.aboutUsesCurrentAppIcon") {
            let settings = try source("SettingsView.swift")
            let icon = try source("ConnectionStatusIcon.swift")
            try expect(settings.contains("Image(nsImage: PaperLikeArtwork.applicationIcon)"),
                       "about displays the bundled application artwork")
            try expect(settings.contains("https://x.com/teno_liu") && !settings.contains("协议参考项目"),
                       "about links to the author's approved public profile")
            try expect(icon.contains("Paperlike-Native-rendered.png")
                       && icon.contains("Paperlike-Native"),
                       "preview and packaged app resolve the same icon design")
            let build = try repositorySource("Tools/build-app.sh")
            try expect(icon.contains("PaperLikeNativeAboutIcon") && build.contains("PaperLikeNativeAboutIcon.png")
                       && build.contains("--export-image"),
                       "about loads the explicit Composer rendition exported by the build")
        },
        TestCase("NativeInterfaceContract.reportsTouchReleaseMetadata") {
            let plist = try repositorySource("Resources/Info.plist")
            let settings = try source("SettingsView.swift")
            try expect(
                plist.contains("<string>1.0.1</string>")
                    && plist.contains("<string>18</string>"),
                "bundle metadata is version 1.0.1 build 18"
            )
            try expect(
                plist.contains("<string>org.paperlike.native</string>"),
                "public application identity has no personal namespace"
            )
            try expect(
                settings.contains("CFBundleShortVersionString") && settings.contains("CFBundleVersion"),
                "About reads the installed bundle version"
            )
        }
    ]
}

private func source(_ filename: String) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let file = root
        .appendingPathComponent("Sources/PaperLikeNativeUI")
        .appendingPathComponent(filename)
    return try String(contentsOf: file, encoding: .utf8)
}

private func repositorySource(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try String(
        contentsOf: root.appendingPathComponent(relativePath),
        encoding: .utf8
    )
}
