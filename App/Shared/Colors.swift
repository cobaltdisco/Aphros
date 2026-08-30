import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 壳层三色。每个都和 `entry.css` 里的对应变量**逐位相同**——CSS 和 Swift 各存
/// 一份同一个颜色，是这个架构里唯一的重复，没有办法消掉（WebView 拿不到
/// SwiftUI 的色，反之亦然）。改 CSS 时这里必须一起改。
///
/// iOS 走 UIColor 的 trait 闭包，macOS 走 NSColor 的 appearance 闭包，
/// 深浅色都由系统在取色时现算。
extension Color {
    /// 版心底色 = `--bg`。候选列表和开屏页是 SwiftUI 铺的，正文是 WebView 铺的，
    /// 两者差一档，从候选切回正文就会闪一下。
    ///
    /// 两个平台**各对各的 CSS**（2026-08-30 用户拍板解耦）：iOS 是原生系
    /// （纯白纯黑，= 系统 systemBackground 两态），macOS 走渲染图方向一
    /// （深色 #111214），对应 entry.css 里 :root 与 :root.mac 两段。
    #if os(macOS)
    static let page = dynamic(
        light: (r: 0xFF, g: 0xFF, b: 0xFF),
        dark:  (r: 0x11, g: 0x12, b: 0x14))
    #else
    static let page = dynamic(
        light: (r: 0xFF, g: 0xFF, b: 0xFF),
        dark:  (r: 0x00, g: 0x00, b: 0x00))
    #endif

    /// 强调色 = `--accent`。正文里的喇叭、雪佛龙、展开开关是这个色，
    /// 搜索框的光标和「取消」也该是。不设的话 SwiftUI 用系统蓝，
    /// 玻璃条和正文说两种颜色。
    /// iOS：浅色 #0071E0 = 系统蓝压深过 AA 的版本（原值 #007AFF 在白底只有
    /// 4.0:1），深色 #0A84FF = 系统深色蓝原值。macOS：渲染图的藏蓝
    /// #1B4C8A / #7FB6F5（对 --bg 8.58:1 / 8.85:1）。
    #if os(macOS)
    static let accent = dynamic(
        light: (r: 0x1B, g: 0x4C, b: 0x8A),
        dark:  (r: 0x7F, g: 0xB6, b: 0xF5))
    #else
    static let accent = dynamic(
        light: (r: 0x00, g: 0x71, b: 0xE0),
        dark:  (r: 0x0A, g: 0x84, b: 0xFF))
    #endif

    /// 收藏的星 = `--fav`。词条页的星是 CSS 画的，列表和过滤钮的星是 SwiftUI 画的。
    static let fav = dynamic(
        light: (r: 0xE9, g: 0xA5, b: 0x0A),
        dark:  (r: 0xFF, g: 0xD6, b: 0x0A))

    private typealias RGB = (r: Int, g: Int, b: Int)

    private static func dynamic(light: RGB, dark: RGB) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                           blue: CGFloat(c.b) / 255, alpha: 1)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                           blue: CGFloat(c.b) / 255, alpha: 1)
        })
        #endif
    }
}
