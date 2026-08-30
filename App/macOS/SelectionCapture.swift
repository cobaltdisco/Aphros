import AppKit
import ApplicationServices
import Carbon.HIToolbox    // kVK_ANSI_C

/// 划词取文本：AX 读选区 → 菜单「拷贝」兜底 → 模拟 ⌘C。
///
/// 编排照 SelectedTextKit（MIT）的成熟约定，实现自己写（B 方案，零依赖）：
///
/// - **AX 主路**：前台 App 焦点元素的 `AXSelectedText`。快、零副作用，
///   顺手还能拿选区的屏幕矩形给浮窗定位。Chromium 系通常也走得通
///   （SelectedTextKit 全套代码里都没有 AXManualAccessibility 那个 hack）。
/// - **菜单拷贝兜底**：不模拟按键，用 AX 找菜单栏的「拷贝」项直接 press。
///   好处有三：菜单项**是灰的就说明没选中文本**，直接放弃——不碰剪贴板、
///   不出提示音、没有空拷贝竞态；App 改过拷贝快捷键不受影响；找菜单项按
///   `AXMenuItemCmdChar == "C"` 认，跨语言可靠。
/// - **模拟 ⌘C 最后兜底**：个别无菜单 App（真到这一步提示音就认了，
///   Easydict 为这声「嘟」拉 AppleScript 静音，不值当）。
///
/// 三级共用一个「辅助功能」授权。
enum SelectionCapture {

    struct Capture {
        let text: String
        /// 选区的屏幕矩形，**AX 全局坐标（左上原点）**——和 AppKit 的
        /// 左下原点相反，浮窗定位时要翻转。菜单/⌘C 路拿不到，为 nil。
        let selectionBounds: CGRect?
    }

    /// 辅助功能授权检查。`prompt: true` 时系统弹引导（一次性）。
    static func ensureTrusted(prompt: Bool) -> Bool {
        // 不引 kAXTrustedCheckOptionPrompt 常量：它是全局 var，Swift 6 并发检查
        // 不放行。字符串值是 ABI 稳定的公开常量值。
        return AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    @MainActor
    static func capture() async -> Capture? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier

        // AX 调用可能阻塞到超时（默认好几秒），不在主线程上等它。
        let ax = await Task.detached(priority: .userInitiated) {
            axSelection(pid: pid)
        }.value
        if let ax, !ax.text.isEmpty { return ax }

        // 剪贴板兜底（NSPasteboard 主线程）。Safari 的拷贝落盘实测偏慢，
        // 超时单独放宽（SelectedTextKit 量出来的 0.2s / 0.4s，先沿用后自证）。
        let timeout: Duration = app.bundleIdentifier == "com.apple.Safari"
            ? .milliseconds(400) : .milliseconds(200)
        if let text = await copyFallback(pid: pid, timeout: timeout), !text.isEmpty {
            return Capture(text: text, selectionBounds: nil)
        }
        return nil
    }

    // MARK: - AX 主路

    nonisolated private static func axSelection(pid: pid_t) -> Capture? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        guard let text = copyAttribute(element, kAXSelectedTextAttribute) as? String,
              !text.isEmpty
        else { return nil }
        return Capture(text: text, selectionBounds: selectionBounds(of: element))
    }

    /// 选区屏幕矩形：`AXSelectedTextRange` → 参数化属性 `AXBoundsForRange`。
    nonisolated private static func selectionBounds(of element: AXUIElement) -> CGRect? {
        guard let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue, &boundsValue) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.width > 0 || rect.height > 0
        else { return nil }
        return rect
    }

    nonisolated private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    // MARK: - 剪贴板兜底

    @MainActor
    private static func copyFallback(pid: pid_t, timeout: Duration) async -> String? {
        if let item = copyMenuItem(pid: pid) {
            // 菜单项灰着 = 前台 App 认为没有可拷贝的选中，到此为止。
            guard menuItemEnabled(item) else { return nil }
            return await pasteboardText(timeout: timeout) {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
            }
        }
        return await pasteboardText(timeout: timeout) { postCommandC() }
    }

    /// 菜单栏里的「拷贝」：逐个顶级菜单找 `CmdChar == "C"` 且修饰键为纯 ⌘ 的项。
    /// 只搜一层——「拷贝」躺在子菜单里的 App 几乎不存在，递归不值当。
    private static func copyMenuItem(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = copyAttribute(app, kAXMenuBarAttribute),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let topItems = children(of: bar as! AXUIElement)
        else { return nil }
        // topItems[0] 是苹果菜单，「拷贝」在编辑菜单——但不按名字认（跨语言），全扫。
        for topItem in topItems.dropFirst() {
            guard let menus = children(of: topItem) else { continue }
            for menu in menus {
                guard let items = children(of: menu) else { continue }
                for item in items {
                    guard let char = copyAttribute(item, kAXMenuItemCmdCharAttribute) as? String,
                          char == "C",
                          let modifiers = copyAttribute(item, kAXMenuItemCmdModifiersAttribute) as? Int,
                          modifiers == 0    // 0 = 只有 ⌘（⇧⌘C 之类是别的命令）
                    else { continue }
                    return item
                }
            }
        }
        return nil
    }

    nonisolated private static func children(of element: AXUIElement) -> [AXUIElement]? {
        guard let value = copyAttribute(element, kAXChildrenAttribute),
              let array = value as? [AnyObject]
        else { return nil }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }

    private static func menuItemEnabled(_ item: AXUIElement) -> Bool {
        (copyAttribute(item, kAXEnabledAttribute) as? Bool) ?? false
    }

    /// 剪贴板协议（照 SelectedTextKit 的约定，Pure Paste 这类剪贴板工具在场
    /// 也能共处）：记 changeCount → 触发拷贝 → 5ms 轮询到超时 → 恢复备份，
    /// 但**只有最后写入者还是我们时才恢复**——窗口期里第三方又写过就不盖人家的。
    @MainActor
    private static func pasteboardText(timeout: Duration,
                                       afterPerform action: () -> Void) async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let backup = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        action()

        var text: String?
        var observed = before
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pasteboard.changeCount != before {
                if let value = pasteboard.string(forType: .string), !value.isEmpty {
                    text = value
                    observed = pasteboard.changeCount
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        if observed != before, pasteboard.changeCount == observed, !backup.isEmpty {
            pasteboard.clearContents()
            pasteboard.writeObjects(backup)
        }
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(kVK_ANSI_C),
                                      keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
