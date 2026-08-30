import AppKit
import Carbon.HIToolbox

/// 全局热键：Carbon `RegisterEventHotKey` 的最小封装。
///
/// 选它不选 NSEvent 全局监听（要「输入监控」权限）也不选三方库（B 方案：
/// 零依赖，2026-08-30 拍板）——Carbon 热键不要任何权限，至今是标准做法。
/// Carbon 事件分发在主线程，回调里 `assumeIsolated` 回 MainActor 是成立的。
@MainActor
final class HotKey {

    /// nonisolated(unsafe)：Swift 6 不许 deinit 碰 MainActor 属性。实际安全——
    /// 两个 ref 只在 init（MainActor）写一次，deinit 只读来注销。
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    let onPress: @MainActor () -> Void

    /// 默认 ⌥D（Bob 的划词翻译同款，肌肉记忆通用）。
    init(keyCode: UInt32 = UInt32(kVK_ANSI_D),
         modifiers: UInt32 = UInt32(optionKey),
         onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.onPress() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4449_4354) /* 'DICT' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
