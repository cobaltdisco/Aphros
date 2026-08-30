import Foundation
import Testing
@testable import DictRender
@testable import MDictKit

/// 字节扫描版的三个 pass 必须和它们替换掉的正则版**逐字节一致**。
///
/// `stripHazards` / `removeSyllableDots` / `wrapPhoneticsInButton` 原先是
/// Swift Regex 写的——Regex 按字素簇走，这三个 pass 在 light（208 KB）上
/// 合计 44 ms，占 transform 的一半多。重写成 UTF-8 字节扫描后语义必须原样：
/// 这里保留被换掉的正则代码当参考实现，在真实词典上抽样差分。
/// 重写当天在 OALDPE 全库 463,860 条上跑过全量差分：0 条不一致。
struct ScanParityTests {

    // MARK: 参考实现（被替换前的原代码，一个字节没改）

    static func referenceStripHazards(_ html: String) -> String {
        var out = html.replacing(/<script\b[^>]*>[\s\S]*?<\/script>/, with: "")
        out = out.replacing(/<link\b[^>]*>/, with: "")
        out = out.replacing(/\s+style="[^"]*"/, with: "")
        out = out.replacing(/\s+on[a-z]+="[^"]*"/, with: "")
        return out
    }

    static func referenceRemoveSyllableDots(_ html: String) -> String {
        html.replacing(/(<h1\b[^>]*class="[^"]*headword[^"]*"[^>]*>)([\s\S]*?)(<\/h1>)/) { match in
            var text = ""
            var inTag = false
            for ch in match.2 {
                if ch == "<" { inTag = true }
                if !(ch == "\u{00B7}" && !inTag) { text.append(ch) }
                if ch == ">" { inTag = false }
            }
            return match.1 + text + match.3
        }
    }

    static func referenceWrapPhonetics(_ html: String) -> String {
        var out = html.replacing(
            /<\/a>\s*<span class="phon_label">([^<]*)<\/span>\s*(<span class="phon">[^<]*<\/span>)/
        ) { match in
            let label = match.1.trimmingCharacters(in: .whitespaces)
            let name = EntryRenderer.phonLabelNames[label] ?? label
            return #"<span class="phon_label">\#(name)</span>\#(match.2)</a>"#
        }
        out = out.replacing(/<\/a>(<span class="phon">[^<]*<\/span>)/) { match in
            String(match.1) + "</a>"
        }
        out = out.replacing(/(<span class="prefix">[^<]*<\/span>)\s*(<a class="sound[^>]*>)/) { match in
            String(match.2) + String(match.1)
        }
        return out
    }

    // MARK: 合成用例（不依赖词典，专捅正则的边角）

    @Test("字节扫描与正则参考在边角输入上一致")
    func syntheticEdgeCases() {
        let cases = [
            "",
            "plain text no tags",
            // script：\b 边界、无闭合、嵌 link
            #"<script src="a.js">var x=1</script>after"#,
            #"<scripts>不是 script 标签</scripts>"#,
            #"<script>没有闭合标签"#,
            #"a<script a>x<link rel="x">y</script>b"#,
            // 属性剥除：前置空白、连续两个、data-style 不误伤
            #"<p style="color:red" onclick="f()">x</p>"#,
            "<p \t\n style=\"a\"  style=\"b\">连续两个、混合空白</p>",
            #"<p data-style="keep" season="keep" onClick="keep-uppercase">x</p>"#,
            #"<p on="太短不匹配" onx="x">y</p>"#,
            // h1：headword 类、嵌子标签、音节点在属性里不动
            #"<h1 class="headword" syllable="a·b">a·b<span class="hm">1</span>·c</h1>"#,
            #"<h1 class="other">a·b</h1>"#,
            #"<h1x class="headword">a·b</h1x>"#,
            // 音标挪位：三种模式 + 相邻/带空白的差别
            #"<a class="sound"></a><span class="phon">/x/</span>"#,
            #"<a class="sound"></a> <span class="phon">/带空格不匹配/</span>"#,
            #"</a> <span class="phon_label"> South African English </span> <span class="phon">/x/</span>"#,
            #"</a><span class="phon_label">Unknown Region</span><span class="phon">/x/</span>"#,
            #"<span class="prefix">strong form</span> <a class="sound s" href="x">y</a>"#,
        ]
        for html in cases {
            #expect(EntryRenderer.stripHazards(html) == Self.referenceStripHazards(html))
            #expect(EntryRenderer.removeSyllableDots(html) == Self.referenceRemoveSyllableDots(html))
            #expect(EntryRenderer.wrapPhoneticsInButton(html) == Self.referenceWrapPhonetics(html))
        }
    }

    // MARK: 真实词典抽样（没有 dicts/ 时跳过）

    @Test("全库抽样：三个 pass 与正则参考逐字节一致")
    func parityOnRealDictionary() throws {
        guard let dict = try RecordTests.dictionary(at: "dicts/oalecd_10_refined/oaldpe.mdx")
        else { return }
        var checked = 0
        // 331 步长 ≈ 1,400 条；管线顺序照 transform 的来，各 pass 拿到的输入和线上一样。
        for index in stride(from: 0, to: dict.keyCount, by: 331) {
            let record = try dict.recordText(at: index)
            let body = EntryRenderer.bodyContent(of: record)
            let stripped = EntryRenderer.stripHazards(body)
            #expect(stripped == Self.referenceStripHazards(body),
                    "stripHazards 分歧 @#\(index) \(dict.key(at: index))")
            let dotless = EntryRenderer.removeSyllableDots(stripped)
            #expect(dotless == Self.referenceRemoveSyllableDots(stripped),
                    "removeSyllableDots 分歧 @#\(index) \(dict.key(at: index))")
            let wrapped = EntryRenderer.wrapPhoneticsInButton(dotless)
            #expect(wrapped == Self.referenceWrapPhonetics(dotless),
                    "wrapPhonetics 分歧 @#\(index) \(dict.key(at: index))")
            checked += 1
        }
        #expect(checked > 1000)
    }
}
