import Foundation
import Testing
@testable import DictRender

/// 纯桥条目（gave → give）的判定与解析。形状取自真词条（probe dump，2026-08-30）。
struct BridgeTargetTests {

    /// gave 词条的骨架：xrefs + entry:// 内链、无任何释义。
    private let bridge = #"""
        <div class="entry" id="gave"><ol class="sense_single"><li class="sense">
        <span class="xrefs" xt="ptof"><span class="prefix">past tense of</span>
        <a class="Ref" href="entry://give#give_1"><span class="xr-g">give</span></a></span>
        </li></ol></div>
        """#

    @Test func 纯桥解析出指向() {
        #expect(EntryRenderer.bridgeTarget(for: bridge) == "give")
    }

    @Test func 带释义的交叉引用不是桥() {
        // see / syn / opp 都长在真词条里（全库 16,924 条），有 def 就绝不能跳
        let real = bridge.replacingOccurrences(
            of: "past tense of",
            with: #"<span class="def">to hand something over</span>past tense of"#)
        #expect(EntryRenderer.bridgeTarget(for: real) == nil)
        let realZh = bridge.replacingOccurrences(
            of: "past tense of",
            with: #"<deft><chn class="simple">给</chn></deft>past tense of"#)
        #expect(EntryRenderer.bridgeTarget(for: realZh) == nil)
    }

    @Test func 重定向与无引用都不是桥() {
        #expect(EntryRenderer.bridgeTarget(for: "@@@LINK=give") == nil)
        #expect(EntryRenderer.bridgeTarget(for: #"<div class="entry">plain</div>"#) == nil)
    }

    @Test func 带百分号编码的指向要解码() {
        let encoded = bridge.replacingOccurrences(of: "entry://give#give_1",
                                                  with: "entry://bar%20chart")
        #expect(EntryRenderer.bridgeTarget(for: encoded) == "bar chart")
    }
}
