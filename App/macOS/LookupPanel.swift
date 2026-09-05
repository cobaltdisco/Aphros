import AppKit
import DictCore
import SwiftUI
import WebKit

/// 划词浮窗（ADR 0011 预留的第二形态，2026-08-30 拍板落地）。
///
/// 无边框 `NSPanel`：`.nonactivatingPanel`——弹出不抢焦点，用户在原 App 里
/// 打字不断流。和主窗口共用同一份 store/history（App 层持有，词典不加载第二次），
/// 词条渲染复用 EntryWebCore，窄版心走 rootClasses 的 `panel` 类。
///
/// 尺寸与行为按预览稿（docs/design/macos-lookup-panel.html，用户拍板甲档去喇叭）：
/// 380px 定宽、高随内容上限 420、弹在选区下方 8px（越底翻上方）、
/// esc / 点外面 / 再按热键关闭。音标即发音按钮（渲染层本来就把音标包进
/// sound:// 链接里，主窗口同款，零改造）。
@MainActor
final class LookupPanelController {

    static let width: CGFloat = 380
    static let maxWebHeight: CGFloat = 420
    static let footerHeight: CGFloat = 28
    /// WebView 和底栏分隔线之间的同色垫层。正文的底距不能写进 CSS：
    /// panel 版心 padding-bottom 为 0 时末块边距整体塌出 body（实测只剩 2.4px），
    /// 给 1px 就全弹回来（跳到 ~18px）——二选一都不是 14，缺口在面板层补齐，
    /// 光学四边才能统一到 14（顶 14.1 / 右 14 / 底 2.4+12）。
    static let webBottomInset: CGFloat = 12

    /// 底栏「在 Aphros 中打开」：把词交给 App 层（LookupRuntime.showMainWindow）。
    /// 浮窗不知道主窗口的生死，也不该知道。
    var openInMain: ((String) -> Void)?

    private let store: DictionaryStore
    private let history: HistoryStore
    private let panel: NSPanel
    private let model = LookupPanelModel()
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var localMonitor: Any?
    /// 这次弹出的锚点（AppKit 坐标）。量完高度定位用。
    private var anchor: Anchor = .mouse(.zero)

    private enum Anchor {
        case selection(CGRect)    // 选区矩形，已翻成 AppKit 左下原点
        case mouse(CGPoint)
    }

    init(store: DictionaryStore, history: HistoryStore) {
        self.store = store
        self.history = history

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = LookupPanelView(
            model: model,
            onPlaySound: { [weak self] in self?.store.play(sound: $0) },
            onToggleFavorite: { [weak self] in
                guard let self, !model.word.isEmpty else { return false }
                return history.toggleFavorite(model.word,
                                              preview: store.preview(for: model.word))
            },
            onOpenInApp: { [weak self] in self?.openInMainWindow() },
            onLoaded: { [weak self] in self?.webViewDidLoad($0) })
        panel.contentView = NSHostingView(rootView: view)
    }

    // MARK: 热键入口

    /// 每次按热键都走完整链路：取到文本 → 弹（或换词）；没取到选区 → 收；
    /// 取到了但查不到 → 也弹，正文换成「没有找到」（用户拍板：不能毫无反应）。
    func trigger() {
        guard SelectionCapture.ensureTrusted(prompt: true) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let capture = await SelectionCapture.capture() else {
                hide()
                return
            }
            anchor = Self.anchor(for: capture.selectionBounds)
            if let hit = lookup(capture.text) {
                model.message = nil
                model.word = hit.word
                history.recordOpen(hit.word, preview: store.preview(for: hit.word))
                if hit.document == model.html {
                    // 同一个词再触发：coordinator 对同文档去重、didFinish 不会
                    // 再来（第一版在这儿死锁成「关了就再也弹不出」），高度是
                    // 现成的，直接摆位露面。
                    present(height: model.height)
                } else {
                    // 先装文档、藏着量高；didFinish 里定尺寸再露面，不闪半成品。
                    model.html = hit.document
                }
            } else {
                // 第一个候选就是修剪后的原文（划词带进来的标点已剥掉），
                // 拿它显示和喂给「在 Aphros 中打开」——主窗口的候选列表
                // 对拼写差一点的词常能救回来。纯标点/空白的选区照旧收起。
                guard let display = DictionaryStore.displayForm(ofSelection: capture.text)
                else {
                    hide()
                    return
                }
                model.word = display
                let shown = display.count > 24 ? display.prefix(24) + "…" : display[...]
                model.message = "没有找到 “\(shown)”"
                present(height: 56 + Self.footerHeight)
            }
        }
    }

    /// 「划中的文本 → 词」的策略（归一化、跟桥、规范词头）全在
    /// DictionaryStore.resolve(selection:)，这里只要文档、挂窄版心。
    private func lookup(_ raw: String) -> (word: String, document: String)? {
        guard let word = store.resolve(selection: raw),
              let document = store.document(for: word,
                                            favorited: history.isFavorite(word),
                                            panel: true)
        else { return nil }
        return (word, document)
    }

    // MARK: 量高 → 定位 → 露面

    private func webViewDidLoad(_ webView: WKWebView) {
        guard !model.word.isEmpty else { return }
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
            guard let self else { return }
            let contentHeight = (value as? Double).map { CGFloat($0) } ?? Self.maxWebHeight
            present(height: min(contentHeight, Self.maxWebHeight)
                            + Self.webBottomInset + Self.footerHeight)
        }
    }

    private func present(height: CGFloat) {
        model.height = height
        panel.setContentSize(NSSize(width: Self.width, height: height))
        place(height: height)
        if !panel.isVisible { panel.orderFrontRegardless() }
        installMonitors()
    }

    private static func anchor(for axBounds: CGRect?) -> Anchor {
        guard let axBounds else { return .mouse(NSEvent.mouseLocation) }
        // AX 全局坐标是左上原点（相对主屏），翻成 AppKit 的左下原点。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGRect(x: axBounds.origin.x,
                             y: primaryHeight - axBounds.maxY,
                             width: axBounds.width, height: axBounds.height)
        return .selection(flipped)
    }

    private func place(height: CGFloat) {
        let topLeft: CGPoint
        switch anchor {
        case .selection(let rect):
            topLeft = CGPoint(x: rect.minX, y: rect.minY - 8)
        case .mouse(let point):
            topLeft = CGPoint(x: point.x, y: point.y - 12)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(topLeft) }
            ?? NSScreen.main
        var origin = CGPoint(x: topLeft.x, y: topLeft.y - height)
        if let visible = screen?.visibleFrame {
            // 越底翻到选区上方；左右夹回屏内。
            if origin.y < visible.minY, case .selection(let rect) = anchor {
                origin.y = rect.maxY + 8
            }
            origin.x = min(max(origin.x, visible.minX + 8),
                           visible.maxX - Self.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: 关闭

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeMonitors()
    }

    /// 点外面收、esc 收。全局 + 本地**两套都要**，只在浮窗可见期间挂着：
    /// 全局监视器只收发给**别的 App** 的事件——点浮窗自己走不到它（天然
    /// 不误伤），但同理，点 Aphros 主窗口、在本 App 里按 esc 它也全聋。
    /// 在自家词条正文里划词时三条收起路一起失灵（⌥D 因选区仍在只会重弹），
    /// 浮窗关不掉（用户报的）。本地监视器补齐同一套约定。
    private func installMonitors() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* esc */ else { return }
            Task { @MainActor in self?.hide() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            // 本地监视器回调在主线程（AppKit 约定），并发检查不知情，
            // 动作处逐个认领（assumeIsolated 不能整体包：返回值 NSEvent
            // 不 Sendable，编译不过）。
            if event.type == .keyDown {
                guard event.keyCode == 53 /* esc */ else { return event }
                MainActor.assumeIsolated { self?.hide() }
                return nil    // esc 只为收浮窗，吞掉
            }
            // 点到浮窗以外的本 App 窗口：收起、事件照常放行给那个窗口。
            let inPanel = MainActor.assumeIsolated { event.window === self?.panel }
            if !inPanel { MainActor.assumeIsolated { self?.hide() } }
            return event
        }
    }

    private func removeMonitors() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        mouseMonitor = nil
        keyMonitor = nil
        localMonitor = nil
    }

    private func openInMainWindow() {
        let word = model.word
        hide()
        openInMain?(word)
    }
}

// MARK: - 内容

@MainActor @Observable
private final class LookupPanelModel {
    var html = ""
    var word = ""
    var height: CGFloat = 200
    /// 非 nil 时正文区不显示词条、显示这行提示（「没有找到 …」）。
    var message: String?
}

private struct LookupPanelView: View {
    let model: LookupPanelModel
    let onPlaySound: (String) -> Void
    let onToggleFavorite: () -> Bool
    let onOpenInApp: () -> Void
    let onLoaded: (WKWebView) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // WebView 常驻不摘（主窗口同一策略）：if/else 切换会把 WKWebView
            // 连进程带状态整个重建，未命中一次、下次命中就要重付冷启动。
            // 提示态只是把它藏在提示后面。
            MacEntryWebView(html: model.html,
                            onPlaySound: onPlaySound,
                            onToggleFavorite: onToggleFavorite,
                            onDidFinish: onLoaded)
                .padding(.bottom, LookupPanelController.webBottomInset)
                .opacity(model.message == nil ? 1 : 0)
                .overlay {
                    if let message = model.message {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                    }
                }
            Divider()
            footer
        }
        .frame(width: LookupPanelController.width, height: model.height)
        .background(Color.page)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // 描边只留深色（12% 白的极细内线，系统深色窗口同款）：深色浮窗浮在
        // 深色内容上没这条线会糊成一片；浅色靠投影交代层级就够，systemColor
        // 的灰描边试过一版，用户看着怪（2026-08-30），去掉。
        .overlay {
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.12))
            }
        }
    }

    /// 底栏（预览稿甲档）：左「在 Aphros 中打开」、右 esc 提示。
    /// 预览稿上的 ↩ 角标不做：浮窗不抢焦点（.nonactivatingPanel），回车实际
    /// 落在用户正在用的 App 里；全局监视器只能旁观不能拦截，做真回车要抢
    /// 焦点，代价大于一次点击。
    private var footer: some View {
        HStack {
            Button("在 Aphros 中打开", action: onOpenInApp)
                .buttonStyle(.plain)
            Spacer()
            Text("esc 关闭")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)    // 和正文的新内衬（14）共线
        .frame(height: LookupPanelController.footerHeight)
    }
}
