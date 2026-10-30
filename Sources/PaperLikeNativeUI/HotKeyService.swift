import PaperlikeLocalization
import Carbon
import Foundation
import PaperlikeCore

enum HotKeyAction: UInt32, CaseIterable {
    case cycleMode = 1
    case refresh = 2
    case thresholdUp = 3
    case thresholdDown = 4

    var title: String {
        switch self {
        case .cycleMode: L("切换显示模式")
        case .refresh: L("快速刷新")
        case .thresholdUp: L("增加对比度")
        case .thresholdDown: L("降低对比度")
        }
    }
}

enum HotKeyServiceError: Error, LocalizedError {
    case duplicate
    case registrationFailed(OSStatus)
    case rollbackFailed(original: String, restore: String)

    var errorDescription: String? {
        switch self {
        case .duplicate: L("快捷键组合重复。")
        case .registrationFailed(let status): L("快捷键注册失败（\(status)）。")
        case .rollbackFailed(let original, let restore): L("\(original) 原快捷键恢复未完成：\(restore)")
        }
    }
}

@MainActor
final class HotKeyService {
    private static let signature: OSType = 0x504C4B43

    private var references: [HotKeyAction: EventHotKeyRef] = [:]
    private(set) var registeredDefinitions: [HotKeyAction: HotKeyDefinition] = [:]
    private var actions: [HotKeyAction: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    private let registerKey: (HotKeyAction, HotKeyDefinition) throws -> EventHotKeyRef
    private let unregisterKey: (EventHotKeyRef) -> Void

    init(
        registerKey: @escaping (HotKeyAction, HotKeyDefinition) throws -> EventHotKeyRef,
        unregisterKey: @escaping (EventHotKeyRef) -> Void
    ) {
        self.registerKey = registerKey
        self.unregisterKey = unregisterKey
    }

    convenience init() {
        self.init(registerKey: Self.registerKey, unregisterKey: { _ = UnregisterEventHotKey($0) })
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    isolated deinit {
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        for reference in references.values {
            unregisterKey(reference)
        }
    }

    func apply(
        definitions: [HotKeyAction: HotKeyDefinition],
        handlers: [HotKeyAction: () -> Void]
    ) throws {
        let values = Array(definitions.values)
        guard Set(values).count == values.count else {
            throw HotKeyServiceError.duplicate
        }

        let previousDefinitions = registeredDefinitions
        let previousActions = actions
        unregisterAll()

        do {
            try register(definitions)
            registeredDefinitions = definitions
            actions = handlers
        } catch {
            unregisterAll()
            do {
                try register(previousDefinitions)
                actions = previousActions
            } catch let restoreError {
                actions = previousActions.filter { references[$0.key] != nil }
                throw HotKeyServiceError.rollbackFailed(original: error.localizedDescription, restore: restoreError.localizedDescription)
            }
            throw error
        }
    }

    func registrationIssues(comparedTo desired: [HotKeyAction: HotKeyDefinition]) -> [HotKeyAction] {
        HotKeyAction.allCases.filter { registeredDefinitions[$0] != desired[$0] }
    }

    private func invoke(id: UInt32) {
        guard let action = HotKeyAction(rawValue: id) else {
            return
        }
        actions[action]?()
    }

    private func register(
        _ definitions: [HotKeyAction: HotKeyDefinition]
    ) throws {
        for action in definitions.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let definition = definitions[action]!
            references[action] = try registerKey(action, definition)
            registeredDefinitions[action] = definition
        }
    }

    private static func registerKey(_ action: HotKeyAction, _ definition: HotKeyDefinition) throws -> EventHotKeyRef {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(definition.keyCode, definition.modifiers, identifier, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw HotKeyServiceError.registrationFailed(status) }
        return reference
    }

    private func unregisterAll() {
        for reference in references.values {
            unregisterKey(reference)
        }
        references.removeAll()
        registeredDefinitions.removeAll()
        actions.removeAll()
    }

    private nonisolated static let callback: EventHandlerUPP = {
        _, event, userData in
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr else {
            return status
        }
        let service = Unmanaged<HotKeyService>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            service.invoke(id: identifier.id)
        }
        return noErr
    }
}
