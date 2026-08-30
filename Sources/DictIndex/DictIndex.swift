import Foundation
import MDictKit

/// L2 索引层。
///
/// 职责：把 MDictKit 读出来的词头重排成可查表（`KeyTable`），提供前缀搜索、
/// 中文词头子串反查、`@@@LINK` 重定向解析。**不做释义全文检索**——OALDPE 自带
/// 18.4 万条中文词头，中→英已经够用，建 FTS 要多付 60–250 MB 索引和 3–5 人日。
///
/// 索引常驻内存、不落 SQLite，理由与实测数字见 `docs/decisions/0008-词头索引不落库.md`。
public struct DictIndex: Sendable {

    /// `@@@LINK=target` 的解析。实测重定向密度约 45%，其中 8.2% 会二级跳，
    /// 因此必须限深并做环检测——`anti-kickback` 在某些实现里会自指成死循环。
    public static func resolveRedirect(
        _ record: String,
        maxHops: Int = 3,
        lookup: (String) throws -> String?
    ) rethrows -> String? {
        var current = record
        var seen = Set<String>()
        for _ in 0..<maxHops {
            guard current.hasPrefix("@@@LINK=") else { return current }
            let target = current.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, seen.insert(target).inserted,
                  let next = try lookup(target) else { return nil }
            current = next
        }
        return current.hasPrefix("@@@LINK=") ? nil : current
    }
}

extension KeyTable {

    /// 一条查到的词条。
    public struct Match: Sendable {
        /// 命中的词头（原样，保留大小写）。
        public let key: String
        /// 正文 HTML。`@@@LINK` 已经跟完。
        public let html: String
        /// 命中是经过重定向到达的，`key` 是重定向前用户看到的词头。
        public let viaRedirect: Bool
    }

    /// 查词。同一个词头可能有多条（「上当」在 OALDPE 里就有两条），全部返回。
    ///
    /// 重定向靠 `exact` 递归解析——`@@@LINK` 的目标必须走**和用户查询同一条**归一化路径，
    /// 否则 `bar-chart` 这种带连字符的目标会在这里静默断链。
    public func lookup(_ query: String) throws -> [Match] {
        let indices = exact(query)
        guard !indices.isEmpty else { return [] }

        var out: [Match] = []
        for index in indices {
            let raw = try dictionary.recordText(at: index)
            let isRedirect = raw.hasPrefix("@@@LINK=")
            guard let html = try DictIndex.resolveRedirect(raw, lookup: { target in
                guard let hit = exact(target).first else { return nil }
                return try dictionary.recordText(at: hit)
            }) else { continue }                       // 断链或成环：跳过，不返回半条
            out.append(Match(key: dictionary.key(at: index), html: html, viaRedirect: isRedirect))
        }
        return out
    }

    /// 词典夹带的**元数据键**：`@topic_…`（457 个）/ `@wordlists_…`（24 个）是词表
    /// 跳转参数，`oalecd_ref_…`（39 个）是附录页。它们用另一套私有标记，渲染出来
    /// 是链接堆或乱码表格，还会污染候选——实测搜 wordlist 刷出 24 条 `@wordlists_…`。
    ///
    /// 只从**候选**里挡掉：`exact()` 不过滤，点内链、输完整键照样打得开，
    /// 数据一个字节没动。注意 `@` 这个键本身是 at 符号的正经词条，不能按
    /// 「@ 开头」一刀切。
    public static func isMetaKey(_ key: String) -> Bool {
        key.hasPrefix("@topic_") || key.hasPrefix("@wordlists_") || key.hasPrefix("oalecd_ref_")
    }

    /// 搜索建议：先前缀、不足再补子串。中文查询直接走子串——中文词头没有「前缀」的概念，
    /// 用户想的是「哪个词条里出现过这两个字」。
    ///
    /// 多取 520 条再过滤元数据键——它们最多成片出现 520 个（@topic 全家），
    /// 取少了会出现「候选明明该满页却只剩两条」。多取的代价可忽略：
    /// prefix 是有序表上多走几步，substring 本来就是整块 blob 一趟 memmem。
    public func suggestions(_ query: String, limit: Int = 30) -> [Int] {
        let fetch = limit + 520
        let isCJK = query.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        if isCJK {
            return Array(substring(query, limit: fetch)
                .filter { !Self.isMetaKey(dictionary.key(at: $0)) }
                .prefix(limit))
        }
        var out = prefix(query, limit: fetch)
        if out.count < fetch {
            let seen = Set(out)
            out += substring(query, limit: fetch - out.count).filter { !seen.contains($0) }
        }
        return Array(out.lazy
            .filter { !Self.isMetaKey(self.dictionary.key(at: $0)) }
            .prefix(limit))
    }
}
