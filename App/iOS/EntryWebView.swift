import SwiftUI
import WebKit

/// 词条正文的承载（iOS）。
///
/// 自己包 `WKWebView`，**不用 iOS 26 的 SwiftUI `WebView`**——后者的 swiftinterface
/// 只有 12 个 modifier，零个跟 scroll-edge 相关，`.scrollEdgeEffectStyle()` 加上去
/// 能编译但静默无效。见 ADR 0003。
/// 包的是 VC 不是 View，理由见底下的 `EntryWebViewController`。
/// 配置与导航拦截在双端共用的 EntryWebCore / EntryWebCoordinator 里。
struct EntryWebView: UIViewControllerRepresentable {

    let html: String
    /// 点了喇叭（`sound://xxx.mp3`）时回调。
    var onPlaySound: (String) -> Void = { _ in }
    /// 点了词头行的收藏星（`fav://toggle`）时回调，返回**新**的收藏状态。
    var onToggleFavorite: () -> Bool = { false }
    /// 右滑（返回手势）的原始事件，透传给壳层驱动词条层滑出。
    var onEdgePan: (UIPanGestureRecognizer) -> Void = { _ in }

    func makeCoordinator() -> EntryWebCoordinator { EntryWebCoordinator() }

    func makeUIViewController(context: Context) -> EntryWebViewController {
        let webView = EntryWebCore.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // WebView 铺满含安全区，底部留白靠 CSS 的 padding 给玻璃条让位——
        // 缩 frame 的话内容不从玻璃下方透出，peek-through 全废。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return EntryWebViewController(webView: webView)
    }

    func updateUIViewController(_ controller: EntryWebViewController, context: Context) {
        // 每次都重新赋值：闭包要捕获**这一轮** body 里的状态引用。
        controller.onEdgePan = onEdgePan
        context.coordinator.onPlaySound = onPlaySound
        context.coordinator.onToggleFavorite = onToggleFavorite
        context.coordinator.load(html, into: controller.webView)
    }
}


/// 正文的宿主：一个只有 `loadView` 的空壳 VC。
///
/// 存在的唯一理由是**顶部安全区**：`.ignoresSafeArea()` 之下，`UIViewRepresentable`
/// 那条路会把 WKWebView 的 `safeAreaInsets` 清成 0，于是 CSS 的
/// `env(safe-area-inset-top)` 跟着是 0，词头压在灵动岛底下（ADR 0004 note ② 记的
/// 就是这个，iOS 26.5 实测仍然复现）。换成 `UIViewControllerRepresentable` 之后
/// 安全区**原样保留**，env() 就有值了。
///
/// 曾经还在这里 KVO `contentOffset` 去驱动自绘的顶部软边缘——那一整套（KVO、
/// 渐变、variableBlur）都撤了：顶部边缘现在是系统原生的滚动边缘效果，由
/// RootView 里那个 1pt 的 safeAreaBar 注册出来，系统自己管画不画。
final class EntryWebViewController: UIViewController, UIGestureRecognizerDelegate {
    let webView: WKWebView
    var onEdgePan: ((UIPanGestureRecognizer) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() { view = webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 右滑返回，挂在 UIKit 这一侧而不是 SwiftUI 手势——SwiftUI 的 DragGesture
        // 得盖一条命中条在 WebView 上，会吃掉底下正文的点击。
        //
        // 用**全页** pan 而不是 UIScreenEdgePanGestureRecognizer：词条正文只有
        // 上下滚动，横向手势没有别的主，不必像系统那样只认贴边起手（用户定的）。
        // 方向闸门在 gestureRecognizerShouldBegin 里：明确的向右横滑才接，
        // 垂直滚动、向左滑、斜着滚都放给 WKWebView 自己的手势。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(backPan))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    @objc private func backPan(_ gesture: UIPanGestureRecognizer) {
        onEdgePan?(gesture)
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        // 1.5 倍是斜滑的裁决线：45° 上下的含糊拖动算滚动，不算返回。
        return velocity.x > abs(velocity.y) * 1.5
    }
}
