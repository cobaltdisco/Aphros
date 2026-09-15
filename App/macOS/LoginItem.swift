import AppKit
import ServiceManagement

/// 开机自启：`SMAppService.mainApp` 的薄封装。ADR 0013 里留的「等真需要再说」，
/// 2026-09-15 用户拍板：只在菜单栏加一个开关，不开设置窗口。
///
/// 不开沙盒、macOS 13+ 的主 App 自己就能当登录项，不需要 helper。登录项记的是
/// **注册那一刻的 App 路径**——从 /Applications 里跑的正式版勾上才有意义，
/// 调试构建勾上记的是编译目录。
@MainActor @Observable
final class LoginItem {

    /// 勾选状态**以系统为准**，不自己存 Bool：用户在「系统设置 › 通用 › 登录项」
    /// 里关掉时，菜单里那个勾要跟着灭。存一份只是让 SwiftUI 有东西可观察，
    /// 每次有菜单开始弹出就 `refresh()` 一遍——不能靠菜单内容的 onAppear，
    /// 实测它只在菜单**第一次**打开时来一次（2026-09-15，三次开菜单只触发 1 次）。
    private(set) var isEnabled = false

    init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // 通知先于菜单内容的 body 求值到达（实测早 6–13 ms），这里刷完
            // body 读到的就是新值；值没变时 SwiftUI 不重算，勾本来就是对的。
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LoginItem: \(on ? "register" : "unregister") failed: \(error)")
        }
        // 用户以前在系统设置里禁过它：register 不报错，状态停在 requiresApproval，
        // 勾不上。直接把那一页打开让他点。
        if on, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refresh()
    }

    /// 这次启动是不是登录项拉起的。**只在 applicationDidFinishLaunching 里问才有
    /// 答案**：loginwindow 拉起登录项时发的 open-application 事件带
    /// `keyAELaunchedAsLogInItem` 标记，而 didFinishLaunching 正是在处理这个事件
    /// 的过程中被调用的；别处 currentAppleEvent 是 nil。
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication),
              let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return Int(prop.enumCodeValue) == keyAELaunchedAsLogInItem
    }
}
