import AppKit
import SwiftUI

@main
struct DictMacApp: App {
    /// Store 建在 App 层而不是视图里（iOS 是 RootView 自持）——划词浮窗
    /// （ADR 0011 预留、0013 落地）是第二个窗口（无边框面板），必须和主窗口
    /// 共用同一份索引、历史和音频——索引常驻内存、源文件 3.3 GB，
    /// 词典不允许被加载两次。
    @State private var store = DictionaryStore()
    @State private var history = HistoryStore()
    /// 热键和浮窗也在 App 层。**不能挂在窗口视图的 @State 上**：关窗即销毁
    /// 视图状态，热键跟着注销，菜单栏形态下划词就死了（第一版真踩了）。
    @State private var runtime = LookupRuntime()

    var body: some Scene {
        // Window 不是 WindowGroup：主窗口是单例。WindowGroup 的 openWindow
        // 每次都**新开一个**（菜单栏「打开 Aphros」连点连开，用户报的），
        // Window 的语义是已开则前置；⌘N 这个多余入口也一并消失。
        Window("Aphros", id: "main") {
            MacRootBootstrap(store: store, history: history, runtime: runtime)
        }
        .defaultSize(width: 920, height: 640)

        // 菜单栏常驻（2026-08-30 用户拍板）：打开 / 屏幕取词开关 / 退出。
        // 主窗口关掉后 App 收进这里继续活着（程序坞里不见），热键照常全局有效。
        // 图标：放大镜找「字」（两批候选里用户选的，docs/design/macos-menubar-icons*.html）
        MenuBarExtra("Aphros", systemImage: "character.magnify") {
            MenuBarContent(runtime: runtime)
        }
    }
}

/// 划词功能的 App 级生命周期：浮窗控制器 + 热键 + 开关持久化。
@MainActor @Observable
final class LookupRuntime {
    private(set) var controller: LookupPanelController?
    private var hotKey: HotKey?

    /// 屏幕取词开关（菜单栏 Toggle 绑它）。**关掉必须注销热键**而不是在回调里
    /// 挡：RegisterEventHotKey 会全局吞掉 ⌥D，只挡回调别的 App 永远收不到它。
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: LookupPanelController.enabledKey)
            syncHotKey()
        }
    }

    init() {
        enabled = UserDefaults.standard
            .object(forKey: LookupPanelController.enabledKey) as? Bool ?? true
    }

    /// 首个窗口起来时调一次（App init 里不建 NSPanel——那会儿 NSApp 还没就绪）。
    func start(store: DictionaryStore, history: HistoryStore) {
        guard controller == nil else { return }
        controller = LookupPanelController(store: store, history: history)
        syncHotKey()
        installCloseWatcher()
    }

    private func syncHotKey() {
        if enabled, hotKey == nil, let controller {
            hotKey = HotKey { controller.trigger() }
        } else if !enabled {
            hotKey = nil    // deinit 注销，⌥D 还给系统
            controller?.hide()
        }
    }

    /// 关窗即收进菜单栏：最后一个主窗口 willClose 后把激活策略降为 accessory
    /// （2026-08-30 用户拍板：关窗只是程序坞里不见），⌘Tab 里也不再出现，
    /// App 和热键照常活着。willClose 时窗口还算 visible，等这轮 runloop 结束
    /// 再数。浮窗是 NSPanel，天然不计入。
    private func installCloseWatcher() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow,
                  !(window is NSPanel), window.canBecomeMain else { return }
            DispatchQueue.main.async {
                let mainWindowsLeft = NSApp.windows.contains {
                    $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain
                }
                if !mainWindowsLeft { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// 主窗口内容 + 引导。包一层不直接用 MacRootView，是因为这里要拿
/// `@Environment(\.openWindow)` 喂给浮窗（「在 Aphros 中打开」要能在主窗口
/// 已销毁时重建它），App 结构体里拿不到环境值。每次窗口重建都重新赋值，
/// 闭包里永远是活的 openWindow。
private struct MacRootBootstrap: View {
    let store: DictionaryStore
    let history: HistoryStore
    let runtime: LookupRuntime

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MacRootView(store: store, history: history)
            // 窗口关了再开，task 会重跑——只在真没加载过时加载，
            // 不然每次重开窗口都重建一遍索引。
            .task { if case .loading = store.phase { await store.load() } }
            .task {
                runtime.start(store: store, history: history)
                runtime.controller?.reopenMainWindow = { openWindow(id: "main") }
            }
    }
}

private struct MenuBarContent: View {
    @Bindable var runtime: LookupRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Aphros") {
            // 从菜单栏形态回到正常形态：程序坞图标回来、窗口重建（或前置）。
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate()
        }
        Toggle("屏幕取词（⌥D）", isOn: $runtime.enabled)
        Divider()
        Button("退出 Aphros") { NSApp.terminate(nil) }
    }
}
