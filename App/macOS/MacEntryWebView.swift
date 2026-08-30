import SwiftUI
import WebKit

/// 词条正文的承载（macOS）。配置与导航拦截和 iOS 完全同源（EntryWebCore），
/// 差异只有三处，都是「iOS 的锅在 Mac 上不存在」：
///
/// - **包 view 不包 VC**：iOS 包 VC 是为了保住 `env(safe-area-inset-top)`
///   （灵动岛让位）；Mac 窗口没有安全区，env() 恒为 0，让位走 html.mac 版心。
/// - **没有返回手势**：双栏里「返回」这个动作不存在。
/// - **透明底走 KVC**：macOS 的 WKWebView 没有 `isOpaque` 也没有 `scrollView`，
///   `"drawsBackground"` 这个 KVC 键是关它自绘底色的通行做法——不关的话
///   深色下换文档会先白闪一帧（WebKit 在 CSS 生效前铺自己的白底）。
struct MacEntryWebView: NSViewRepresentable {

    let html: String
    /// 点了喇叭（`sound://xxx.mp3`）时回调。
    var onPlaySound: (String) -> Void = { _ in }
    /// 点了词头行的收藏星（`fav://toggle`）时回调，返回**新**的收藏状态。
    var onToggleFavorite: () -> Bool = { false }
    /// 文档加载完成（浮窗量高用；主窗口不传）。
    var onDidFinish: (WKWebView) -> Void = { _ in }

    func makeCoordinator() -> EntryWebCoordinator { EntryWebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = EntryWebCore.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 每次都重新赋值：闭包要捕获**这一轮** body 里的状态引用。
        context.coordinator.onPlaySound = onPlaySound
        context.coordinator.onToggleFavorite = onToggleFavorite
        context.coordinator.onDidFinish = onDidFinish
        context.coordinator.load(html, into: webView)
    }
}
