import Foundation

/// 空壳主词条：正文没有一个义项，只剩一张短语动词链接表。
///
/// OALDPE 里 regale / rely / derive / devote 这类动词（全库实测 41 个，2026-09-06）
/// 离开介词就没有意义，第 10 版把释义整个搬进了独立的短语动词条目（`regale with`、
/// `rely on`），主词条只留一个 `entry://` 链接列表——而 25 号元素正好把这张表藏了，
/// 键入 regale 看到的就是词头 + 音标、一行正文都没有。
///
/// 第 8 版对同一批词的做法是把「PHR V regale sb with sth」**内联**在主词条里
///（逐个对过，41 个词第 8 版也全都没有独立义项，释义文字和第 10 版逐字相同）。
/// 这里做同一件事：把链接指向的短语动词条目的 `.pv-g` 块接进主词条，数据全来自
/// 现用词典，不引第二本（ADR 0007）。
extension EntryRenderer {

    /// 空壳主词条挂着的短语动词键（`entry://regale-with#…` → `regale-with`），
    /// 按出现顺序去重。有义项的词条一律返回空——它们的链接表该藏就藏。
    public static func phrasalVerbGrafts(for record: String) -> [String] {
        guard !record.hasPrefix("@@@LINK="),
              !record.contains(#"class="sense""#),
              !record.contains(#"class="def""#),
              !record.contains("<deft"),
              let aside = record.range(of: #"<aside class="phrasal_verb_links""#),
              let asideEnd = record.range(of: "</aside>", range: aside.upperBound..<record.endIndex)
        else { return [] }
        let links = record[aside.upperBound..<asideEnd.lowerBound]
        var out: [String] = []
        var cursor = links.startIndex
        while let ref = links.range(of: #"href="entry://"#, range: cursor..<links.endIndex) {
            cursor = ref.upperBound
            guard let end = links[cursor...].firstIndex(where: { $0 == "\"" || $0 == "#" }) else { break }
            let target = String(links[cursor..<end])
            let decoded = target.removingPercentEncoding ?? target
            if !decoded.isEmpty, !out.contains(decoded) { out.append(decoded) }
        }
        return out
    }

    /// 把短语动词条目里的 `.pv-g` 块接到主词条的链接表前面。`phrasalVerbRecords`
    /// 是 `phrasalVerbGrafts` 返回的键各自查到的原始正文，顺序一致。
    /// 一个块都抽不到、或主词条找不到链接表，原样返回（锚定 + 失败即放过）。
    public static func graftPhrasalVerbs(_ record: String, phrasalVerbRecords: [String]) -> String {
        guard let aside = record.range(of: #"<aside class="phrasal_verb_links""#) else { return record }
        let blocks = phrasalVerbRecords.flatMap(phrasalVerbBlocks)
        guard !blocks.isEmpty else { return record }
        return String(record[..<aside.lowerBound]) + blocks.joined() + String(record[aside.lowerBound...])
    }

    /// 一条短语动词条目里的全部 `<span class="pv-g">…</span>`（`fend off` 这种
    /// 有两个式子的条目是两块）。
    static func phrasalVerbBlocks(in record: String) -> [String] {
        var out: [String] = []
        var cursor = record.startIndex
        while let open = record.range(of: #"<span class="pv-g""#, range: cursor..<record.endIndex) {
            guard let end = endOfElement(in: record, tag: "span", openingAt: open.lowerBound) else { break }
            out.append(String(record[open.lowerBound..<end]))
            cursor = end
        }
        return out
    }
}
