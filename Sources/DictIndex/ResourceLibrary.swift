import Foundation
import MDictKit

/// mdd 资源库：把正文里的 `sound://` / `<img src>` 引用解析成字节。
///
/// 一部词典可以有多个 mdd（OALDPE 分了四个：界面图标、单词发音 mp3、插图 jpg、
/// 例句朗读 ogg），按打开顺序依次找，先命中先用。
public struct ResourceLibrary: Sendable {

    private let volumes: [KeyTable]

    public init(_ dictionaries: [MDict]) {
        self.volumes = dictionaries.map { KeyTable($0) }
    }

    /// 各卷的查询表已经建好（走了索引缓存）时用这个，不再重排。
    public init(tables: [KeyTable]) {
        self.volumes = tables
    }

    public var isEmpty: Bool { volumes.isEmpty }
    public var resourceCount: Int { volumes.reduce(0) { $0 + $1.dictionary.keyCount } }

    /// 清掉各卷的解压区块缓存（内存警告时调用）。索引本身不动——重建它才是大钱。
    public func purgeCaches() {
        for volume in volumes { volume.dictionary.purgeCache() }
    }

    // MARK: 路径归一化

    /// 把正文里的引用变成 mdd 的键。
    ///
    /// 四步，顺序不能换：
    /// 1. **urldecode** —— 例句朗读的路径带 `%23`（就是 `#`），不解就永远找不到。
    /// 2. `/` 换成 `\` —— mdd 的键一律用反斜杠。
    /// 3. 补上开头的 `\`。
    /// 4. 小写。实测 OALDPE 的 16 万个键**含大写的是 0 个**，这步在这部词典上
    ///    是空操作，留着是为了换词典时不至于静默漏掉。
    ///
    /// 实测命中率 **98.43%**（抽样 1,275 个单词发音引用，命中 1,255）。
    /// 剩下的 1.57% 是**词典自己缺文件**——`\internet_banking_1_gb_1.mp3`、
    /// `\livestreamer__gb_1.mp3` 在 mdd 里根本不存在，没有任何归一化规则能救。
    public static func normalize(_ reference: String) -> String {
        var path = reference.removingPercentEncoding ?? reference
        path = path.replacingOccurrences(of: "/", with: "\\")
        if !path.hasPrefix("\\") { path = "\\" + path }
        return path.lowercased()
    }

    // MARK: 取资源

    /// 有没有这个资源。用来把点了没反应的喇叭提前藏掉。
    public func contains(_ reference: String) -> Bool {
        let key = Self.normalize(reference)
        return volumes.contains { !$0.exact(key).isEmpty }
    }

    /// 资源的原始字节。找不到返回 nil。
    ///
    /// **不做任何模糊匹配**：`exact` 是逐字节比对的。ADR 0002 记的 mdict-cpp
    /// 16% 音频错配，成因就是二分查找命中后不校验相等，`\worded__gb_1.mp3`
    /// 会返回 `\word_perfect_1_gb_1.mp3` 的内容——喇叭照按，声音"像是对的"，
    /// UI 上完全无症状。
    public func data(for reference: String) throws -> Data? {
        let key = Self.normalize(reference)
        for volume in volumes {
            guard let index = volume.exact(key).first else { continue }
            return try volume.dictionary.recordData(at: index)
        }
        return nil
    }
}
