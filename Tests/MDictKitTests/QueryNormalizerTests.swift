import Foundation
import Testing
@testable import DictIndex

/// 划词归一化。用例即实测未命中清单（2026-08-30 探针，见 QueryNormalizer 注释）：
/// 屈折形索引本身能吃掉，归一化只负责标点、所有格、屈折短语这三类。
struct QueryNormalizerTests {

    @Test func 首尾标点与弯引号() {
        #expect(QueryNormalizer.candidates(for: "word.").first == "word")
        #expect(QueryNormalizer.candidates(for: "word,").first == "word")
        #expect(QueryNormalizer.candidates(for: "“word”").first == "word")
        #expect(QueryNormalizer.candidates(for: " (word) ").first == "word")
    }

    @Test func 所有格剥尾不动词中() {
        #expect(QueryNormalizer.candidates(for: "word’s").contains("word"))
        #expect(QueryNormalizer.candidates(for: "children's").contains("children"))
        #expect(QueryNormalizer.candidates(for: "words'").contains("words"))
        // don't / it's 是正经词条（实测命中），撇号在词中间不能碰
        #expect(QueryNormalizer.candidates(for: "don't").first == "don't")
    }

    @Test func 屈折短语还原() {
        // gave up 查不到、give up 查得到（实测）——归一化的核心场景
        #expect(QueryNormalizer.candidates(for: "gave up").contains("give up"))
    }

    @Test func 句子降级到首词() {
        let candidates = QueryNormalizer.candidates(for: "gleaned from letters")
        #expect(candidates.contains("gleaned"))    // 首词
        #expect(candidates.contains("glean"))      // 首词还原
    }

    @Test func 原样优先且去重() {
        // 索引大小写不敏感（实测 RUNNING 命中），原样必须排第一——
        // 词典里就有的键（running）不该被还原形（run）抢先
        let candidates = QueryNormalizer.candidates(for: "running")
        #expect(candidates.first == "running")
        #expect(Set(candidates).count == candidates.count)
    }

    @Test func 垃圾输入() {
        #expect(QueryNormalizer.candidates(for: "   ").isEmpty)
        #expect(QueryNormalizer.candidates(for: "…—“”").isEmpty)
        #expect(QueryNormalizer.candidates(for: "").isEmpty)
    }

    @Test func 中文原样通过() {
        #expect(QueryNormalizer.candidates(for: "上当").first == "上当")
    }
}
