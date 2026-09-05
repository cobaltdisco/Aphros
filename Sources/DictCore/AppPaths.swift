import Foundation

/// 双端的文件落点。iOS 在自己的沙盒里，路径怎么写都不越界；macOS 版**不开沙盒**
/// （纯自用不上架，ADR 0011），Documents 和 Application Support 都是公共地盘，
/// 必须圈出自己的子目录。
///
/// 目录名保持 `Dict`：App 显示名 2026-08-30 改成了 Aphros，但改这两个路径
/// 意味着用户手动挪 3.3 GB 词典、索引缓存和历史跟着作废——显示名和落盘
/// 路径解耦，bundle id（com.fx.dict*）同理不动。
extension URL {
    /// 词典文件（.mdx / .mdd）的根目录，任意深度递归查找。
    ///
    /// - iOS：沙盒 Documents。文件共享开着，用户从「文件」App / Finder 拖进来。
    /// - macOS：`~/Documents/Dict`。不能直接扫 `~/Documents`——那是用户的整个
    ///   文稿目录，递归扫一遍又慢又越界（还会把 TCC 授权弹窗的必要性扩大到
    ///   全部文稿）。
    public nonisolated static var dictionariesRoot: URL {
        #if os(macOS)
        documentsDirectory.appending(path: "Dict")
        #else
        documentsDirectory
        #endif
    }

    /// 本 App 在 Application Support 里的落点（索引缓存、history.json）。
    ///
    /// iOS 沙盒里它就是根；macOS 不开沙盒时 `~/Library/Application Support`
    /// 是所有 App 共用的，直接把 `history.json` 扔在顶层等于乱丢垃圾。
    public nonisolated static var dictSupportDirectory: URL {
        #if os(macOS)
        applicationSupportDirectory.appending(path: "Dict")
        #else
        applicationSupportDirectory
        #endif
    }
}
