import AppKit
import DictCore
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
    /// 屏幕取词开关的 UserDefaults 键。住在开关的主人这里（曾经落在浮窗
    /// 控制器里——「谁先用谁收留」的归属漂移，2026-08-31 归位）。
    static let enabledKey = "selectionLookupEnabled"

    private(set) var controller: LookupPanelController?
    private var hotKey: HotKey?

    /// 主窗口被请到前台时该呈现什么（2026-09-05 用户拍板，两个入口两种意图）：
    /// 浮窗「在 Aphros 中打开」是想接着看那个词，保持窗口原状只换词；
    /// 菜单栏「打开 Aphros」是重新开始，回欢迎页、历史列表回到最新一条。
    enum Request: Equatable {
        case word(String)
        case welcome
    }

    /// 主窗口待处理的请求——入口写、MacRootView 读后清空。
    /// **跨窗口状态只走这一条通道**（2026-08-31 收编）：之前是「窗口活着走
    /// 通知、窗口已销毁走静态变量」两条，改一条忘一条。Runtime 全程存活且
    /// 可观察，主窗口用 onChange(initial: true) 盯它：活着时属性变化触发，
    /// 重建时出现那一刻触发，一条路覆盖两种生命周期。
    var pendingRequest: Request?
    /// 主窗口已销毁时重建它（拿 openWindow 环境值的视图注入）。
    var reopenMainWindow: (() -> Void)?

    /// 屏幕取词开关（菜单栏 Toggle 绑它）。**关掉必须注销热键**而不是在回调里
    /// 挡：RegisterEventHotKey 会全局吞掉 ⌥D，只挡回调别的 App 永远收不到它。
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            syncHotKey()
        }
    }

    init() {
        enabled = UserDefaults.standard
            .object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// 首个窗口起来时调一次（App init 里不建 NSPanel——那会儿 NSApp 还没就绪）。
    func start(store: DictionaryStore, history: HistoryStore) {
        guard controller == nil else { return }
        let controller = LookupPanelController(store: store, history: history)
        controller.openInMain = { [weak self] word in self?.showMainWindow(.word(word)) }
        self.controller = controller
        syncHotKey()
        installCloseWatcher()
    }

    /// 把主窗口请到前台（程序坞图标回来、已开则前置、已销毁则重建），
    /// 顺带捎上它该呈现什么。菜单栏「打开」和浮窗「在 Aphros 中打开」
    /// 都走这里——两个入口一份实现。
    func showMainWindow(_ request: Request) {
        NSApp.setActivationPolicy(.regular)
        pendingRequest = request
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenMainWindow?()
        }
        // 不能用 NSApp.activate()：macOS 14 起激活是「协作式」，菜单栏 App
        // 自己喊 activate() 系统不理，窗口出来了却压在别的 App 后面（2026-09-05
        // 用户报）。小实验 App 逐个量过五种写法：activate() 同步 / 推迟一轮都
        // 不行；activate(from:options:) 带 ignoringOtherApps 能到前台，这是
        // 14 起给这种场景的正式接口（旧的 activate(ignoringOtherApps:) 也能，
        // 但已弃用）。推迟一轮让策略切换先落地。
        DispatchQueue.main.async {
            if let front = NSWorkspace.shared.frontmostApplication {
                NSRunningApplication.current.activate(from: front, options: [.activateIgnoringOtherApps])
            } else {
                NSApp.activate()
            }
        }
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
/// `@Environment(\.openWindow)` 喂给 Runtime（主窗口已销毁时靠它重建），
/// App 结构体里拿不到环境值。每次窗口重建都重新赋值，闭包里永远是活的
/// openWindow。
private struct MacRootBootstrap: View {
    let store: DictionaryStore
    let history: HistoryStore
    let runtime: LookupRuntime

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MacRootView(store: store, history: history, runtime: runtime)
            // 窗口关了再开，task 会重跑——只在真没加载过时加载，
            // 不然每次重开窗口都重建一遍索引。
            .task { if case .loading = store.phase { await store.load() } }
            .task {
                runtime.start(store: store, history: history)
                runtime.reopenMainWindow = { openWindow(id: "main") }
            }
    }
}

private struct MenuBarContent: View {
    @Bindable var runtime: LookupRuntime
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 Aphros") {
            // 菜单自己的 openWindow 一定是活的，先刷进 Runtime 再走同一份实现。
            runtime.reopenMainWindow = { openWindow(id: "main") }
            runtime.showMainWindow(.welcome)
        }
        Toggle("屏幕取词（⌥D）", isOn: $runtime.enabled)
        Divider()
        Button("退出 Aphros") { NSApp.terminate(nil) }
    }
}
