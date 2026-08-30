import Foundation
import WebKit

/// `dict://` 的资源服务：样式表从 App 包里取，**其他一律 404**。
///
/// 404 才是剥掉词典脚本的主防线。OALDPE 那 1,703 行 JS（`touchToTranslate` 点例句
/// 切中文、`showSyllable` 点单词切音节、还有个内置配置页）会跟 iOS 的长按选词抢
/// 事件。渲染层已经把 `<script>` 标签剥掉了，这里再堵一道：就算漏了一个，
/// 请求也拿不到文件，脚本注册不了任何监听。
///
/// mdd 里的图片和发音将来也从这里出（M4），所以路径按 `dict://<域>/<路径>` 分。
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "dict"

    /// 已经被 WebView 取消的 task。
    ///
    /// **`didStopLoading` 之后再调 `didReceive` / `didFinish` 会直接抛 NSException 崩溃**，
    /// 这是 WKURLSchemeHandler 最常见的崩法。所以取消状态必须记下来，而且要加锁——
    /// stop 在主线程来，而资源读取会挪到后台。
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        _ = lock.withLock { stopped.remove(id) }

        guard let url = task.request.url else { return finish(task, id: id, status: 400) }
        let name = url.lastPathComponent

        guard url.host() == "asset",
              ["css"].contains(url.pathExtension.lowercased()),
              let file = Bundle.main.url(forResource: name, withExtension: nil),
              let data = try? Data(contentsOf: file)
        else { return finish(task, id: id, status: 404) }

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/css; charset=utf-8",
                                                      "Content-Length": String(data.count)])!
        guard alive(id) else { return }
        task.didReceive(response)
        guard alive(id) else { return }
        task.didReceive(data)
        guard alive(id) else { return }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        lock.withLock { _ = stopped.insert(ObjectIdentifier(task)) }
    }

    private func alive(_ id: ObjectIdentifier) -> Bool {
        lock.withLock { !stopped.contains(id) }
    }

    private func finish(_ task: any WKURLSchemeTask, id: ObjectIdentifier, status: Int) {
        guard alive(id), let url = task.request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        task.didReceive(response)
        guard alive(id) else { return }
        task.didReceive(Data())
        guard alive(id) else { return }
        task.didFinish()
    }
}
