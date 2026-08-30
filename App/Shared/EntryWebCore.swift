import WebKit

/// 词条 WebView 的平台无关核心：配置工厂 + 导航拦截。
///
/// iOS / macOS 的 representable 都从这里拿配置好的 WKWebView 和 coordinator；
/// 将来的取词浮窗（ADR 0011 预留的第二形态）也直接复用——正文 HTML 是同一份，
/// 「零脚本 + dict:// 资源 + 三个私有 scheme」这套约定必须处处一致。
@MainActor
enum EntryWebCore {
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        // 词典正文一个字节的脚本都不需要跑。这一项让 <script> 即使漏剥也不会执行。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = false
        return WKWebView(frame: .zero, configuration: configuration)
    }
}

/// 词条页的导航拦截与文档加载。
///
/// 闭包每轮 body 求值都要重新赋值（捕获这一轮的状态引用），见各 representable
/// 的 update 方法。
final class EntryWebCoordinator: NSObject, WKNavigationDelegate {
    /// 点了喇叭（`sound://xxx.mp3`）。
    var onPlaySound: (String) -> Void = { _ in }
    /// 点了词头行的收藏星（`fav://toggle`），返回**新**的收藏状态。
    var onToggleFavorite: () -> Bool = { false }
    /// 文档加载完成。浮窗拿它量正文高度来定面板尺寸；主窗口不用（默认空操作）。
    var onDidFinish: (WKWebView) -> Void = { _ in }

    private var loadedHTML: String?

    func load(_ html: String, into webView: WKWebView) {
        guard loadedHTML != html else { return }
        loadedHTML = html
        // baseURL 指向 handler 的域，正文里的相对路径（样式表、将来的图片）自动落到它上面。
        webView.loadHTMLString(html, baseURL: URL(string: "\(AssetSchemeHandler.scheme)://asset/"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinish(webView)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }

        if url.scheme == "entry" {
            // 内链已去掉（2026-08-30 用户拍板）：词条间不再跳转。
            // 拦截必须留着——点到残留的 <a href="entry://…"> 时 WKWebView
            // 会真去导航这个 scheme，不拦就是一次报错的页面加载。
            return .cancel
        }
        if url.scheme == "fav" {
            let nowFavorite = onToggleFavorite()
            // 星的实心/空心 = 根元素上有没有 faved 类，切类就是全部工作。
            // `allowsContentJavaScript = false` 只禁**页面自带**的脚本，
            // 壳层 evaluateJavaScript 注入的照常执行（文档写明，实测确认）。
            // async 版有个坑：脚本求值结果是 undefined/null 时它直接崩
            // （返回值按非可选 Any 强解，fatal error，try? 兜不住）。这里最后
            // 一个表达式是 classList.toggle，规范保证返回布尔，才敢用 async 版
            // ——改这行脚本时必须保住「最后一个表达式有值」。
            _ = try? await webView.evaluateJavaScript(
                "document.documentElement.classList.toggle('faved', \(nowFavorite))")
            return .cancel
        }
        if url.scheme == "sound" {
            // sound://abandon__gb_2.mp3 —— host 才是文件名，path 一般是空的。
            // 例句朗读的路径带 %23，解码留给资源库做（它要和 mdd 的键对齐）。
            let reference = (url.host() ?? "") + url.path()
            if !reference.isEmpty { onPlaySound(reference) }
            return .cancel
        }

        // 页内锚点放行——同文档跳转，WKWebView 自己滚过去，不需要脚本。
        if url.scheme == AssetSchemeHandler.scheme, url.fragment() != nil { return .allow }

        // loadHTMLString 自己那一次导航放行，其余一律拦下。
        return action.navigationType == .other ? .allow : .cancel
    }
}
