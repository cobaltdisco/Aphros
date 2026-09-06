import Foundation
import Testing
@testable import DictRender

/// 空壳主词条接短语动词正文（regale → regale with）。形状取自真词条（2026-09-06）。
struct PhrasalVerbGraftTests {

    /// regale 主词条的骨架：词头 + 链接表，没有一个义项。
    private let shell = #"""
        <body-content class="oaldpe"><div id="entryContent" class="oald"><div class="entry" id="regale">
        <div class="top-container"><h1 class="headword">regale</h1> <span class="pos">verb</span>
        <span class="unbox"><chn class="simple">词源</chn></span></div>
        <aside class="phrasal_verb_links" id="regale_pvgs_1"><ul class="pvrefs">
        <li class="li"><a class="Ref" href="entry://regale-with#regalewith2_e"><span class="xh">regale with</span></a></li>
        <li class="li"><a class="Ref" href="entry://regale%20with#x"><span class="xh">dup</span></a></li>
        <li class="li"><a class="Ref" href="entry://fend-off"><span class="xh">fend off</span></a></li>
        </ul></aside></div></div></body-content>
        """#

    /// regale with 条目：一个 pv-g 块，块里还嵌着别的 span。
    private let pvEntry = #"""
        <div class="entry" id="regale-with"><div class="top-container"><h1 class="headword">regale with</h1></div>
        <span class="pv-g" id="regale_pvg_1"><span class="pv">regale somebody with something</span>
        <ol class="sense_single"><li class="sense"><span class="def">to entertain somebody</span></li></ol></span>
        </div>
        """#

    @Test func 空壳抽出全部链接并去重() {
        #expect(EntryRenderer.phrasalVerbGrafts(for: shell) == ["regale-with", "regale with", "fend-off"])
    }

    @Test func 有义项的词条不算空壳() {
        let real = shell.replacingOccurrences(
            of: #"<span class="pos">verb</span>"#,
            with: #"<span class="pos">verb</span><span class="def">x</span>"#)
        #expect(EntryRenderer.phrasalVerbGrafts(for: real).isEmpty)
        #expect(EntryRenderer.phrasalVerbGrafts(for: "@@@LINK=regale-with").isEmpty)
        #expect(EntryRenderer.phrasalVerbGrafts(for: #"<div class="entry">plain</div>"#).isEmpty)
    }

    @Test func 块接在链接表前面且嵌套完整() {
        let out = EntryRenderer.graftPhrasalVerbs(shell, phrasalVerbRecords: [pvEntry, pvEntry])
        let pv = out.range(of: #"<span class="pv-g""#)!
        let aside = out.range(of: "<aside")!
        #expect(pv.lowerBound < aside.lowerBound)
        #expect(out.components(separatedBy: #"class="pv-g""#).count - 1 == 2)
        #expect(out.contains("to entertain somebody</span></li></ol></span><span class=\"pv-g\""))
        #expect(!out.contains(#"id="regale-with""#))     // 只搬 pv-g，不搬对方的词头
    }

    @Test func 抽不到块就原样放过() {
        #expect(EntryRenderer.graftPhrasalVerbs(shell, phrasalVerbRecords: ["<div>nothing</div>"]) == shell)
        #expect(EntryRenderer.graftPhrasalVerbs("no aside", phrasalVerbRecords: [pvEntry]) == "no aside")
    }

    @Test func 空壳不是桥() {
        #expect(EntryRenderer.bridgeTarget(for: shell) == nil)
    }
}
