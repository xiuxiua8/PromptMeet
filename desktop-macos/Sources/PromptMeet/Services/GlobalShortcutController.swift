import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalShortcutController {
    enum Action: UInt32, CaseIterable {
        case quickAsk = 1
        case workspace = 2
        case reader = 3
        case recording = 4

        var keyCode: UInt32 {
            switch self {
            case .quickAsk: UInt32(kVK_ANSI_P)
            case .workspace: UInt32(kVK_ANSI_M)
            case .reader: UInt32(kVK_ANSI_A)
            case .recording: UInt32(kVK_ANSI_R)
            }
        }
    }

    private var actions: [Action: () -> Void]
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []

    init(actions: [Action: () -> Void]) {
        self.actions = actions
    }

    func start() {
        guard handler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
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
                guard status == noErr,
                      let action = Action(rawValue: identifier.id)
                else { return status }
                let controller = Unmanaged<GlobalShortcutController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in controller.actions[action]?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        for action in Action.allCases {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: OSType(0x504D4545),
                id: action.rawValue
            )
            RegisterEventHotKey(
                action.keyCode,
                UInt32(cmdKey | shiftKey),
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if let reference { hotKeys.append(reference) }
        }
    }

    isolated deinit {
        hotKeys.forEach { _ = UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
