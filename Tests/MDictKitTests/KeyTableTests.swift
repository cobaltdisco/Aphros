import DictIndex
import Foundation
import Testing
@testable import MDictKit

/// M2 查询表。这里守的是**静默查不到词**这一类错误——它不抛异常、不崩，
/// 只是搜索框里什么都不出来，最难发现。
struct KeyTableTests {

    nonisolated(unsafe) private static var built: [String: KeyTable] = [:]
    private static let lock = NSLock()

    static func table(for spec: GoldenTests.Goldens.Dictionary) throws -> KeyTable? {
        guard let dict = try RecordTests.dictionary(at: spec.path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = built[spec.path] { return hit }
        let table = KeyTable(dict)
        built[spec.path] = table
        return table
    }

    // MARK: 不变式

    @Test("排序后按折叠字节严格不减", arguments: GoldenTests.goldens.dictionaries)
    func orderIsSorted(_ spec: GoldenTests.Goldens.Dictionary) throws {
        guard let table = try Self.table(for: spec) else { return }
        let dict = table.dictionary
        #expect(table.order.count == dict.keyCount)

        var disorder = 0
        var previous = dict.keyBytes(at: Int(table.order[0])).map(KeyTable.fold)
        for i in 1..<table.order.count {
            let current = dict.keyBytes(at: Int(table.order[i])).map(KeyTable.fold)
            var less = false
            var decided = false
            for j in 0..<min(current.count, previous.count) where current[j] != previous[j] {
                less = current[j] < previous[j]; decided = true; break
            }
            if !decided { less = current.count < previous.count }
            if less { disorder += 1 }
            previous = current
        }
        #expect(disorder == 0, "\(spec.id) 有 \(disorder) 处乱序——二分会静默漏词")
    }

    @Test("每个词头都能用它自己查回自己", arguments: GoldenTests.goldens.dictionaries)
    func everyKeyIsFindable(_ spec: GoldenTests.Goldens.Dictionary) throws {
        guard let table = try Self.table(for: spec) else { return }
        let dict = table.dictionary
        // 全量 46 万次 exact 要十几秒，等距抽 20,000 条：既覆盖首尾也覆盖中间。
        let step = max(1, dict.keyCount / 20_000)
        var missing: [String] = []
        for i in stride(from: 0, to: dict.keyCount, by: step) {
            let key = dict.key(at: i)
            if !table.exact(key).contains(i) { missing.append(key) }
        }
        #expect(missing.isEmpty, "\(spec.id) 查不回来的词头（前 5 条）：\(missing.prefix(5))")
    }

    // MARK: 归一化

    @Test("大小写与首尾空白不影响查词")
    func normalizationIsForgiving() throws {
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        let canonical = table.exact("abandon")
        #expect(!canonical.isEmpty)
        #expect(table.exact("ABANDON")     == canonical)
        #expect(table.exact("Abandon")     == canonical)
        #expect(table.exact("  abandon  ") == canonical)
        #expect(table.exact("\tabandon\n") == canonical)
        // 但**不**剥标点：OALDPE 的 StripKey 是 No，替它剥就是 ADR 0002 里那个 30% 查错的成因。
        #expect(table.exact("bar-chart") != table.exact("barchart"))
    }

    @Test("同名词头全部返回，不能只给第一条")
    func duplicateKeysAllReturned() throws {
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        // 「上当」在 OALDPE 里是两条不同的词条，goldens.json 里两条的 sha256 也不同。
        #expect(table.exact("上当").count == 2)
        let matches = try table.lookup("上当")
        #expect(matches.count == 2)
        #expect(matches[0].html != matches[1].html)
    }

    // MARK: 搜索

    @Test("前缀搜索按序返回")
    func prefixSearch() throws {
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        let hits = table.prefix("aban", limit: 8).map { table.dictionary.key(at: $0) }
        #expect(hits.first == "abandon")
        #expect(hits.allSatisfy { $0.lowercased().hasPrefix("aban") })
        #expect(hits == hits.sorted { $0.lowercased() < $1.lowercased() })
    }

    @Test("中文词头子串反查")
    func chineseSubstringSearch() throws {
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        let hits = table.suggestions("自作", limit: 10).map { table.dictionary.key(at: $0) }
        #expect(hits.contains("自作自受"))
        #expect(hits.contains("自作聪明"))
        #expect(hits.allSatisfy { $0.contains("自作") })
    }

    // MARK: 重定向

    @Test("@@@LINK 跟到底，返回目标词条的正文")
    func redirectsAreFollowed() throws {
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        let dict = table.dictionary

        for (from, to) in [("#", "number"), ("#metoo", "me-too")] {
            let matches = try table.lookup(from)
            #expect(matches.count == 1, "\(from) 应当查到一条")
            let match = try #require(matches.first)
            #expect(match.viaRedirect, "\(from) 是重定向")
            #expect(match.key == from, "显示的词头应当是用户查的那个，不是目标")
            #expect(!match.html.hasPrefix("@@@LINK="), "重定向没跟完")

            let target = try #require(table.exact(to).first)
            #expect(match.html == (try dict.recordText(at: target)), "\(from) 的正文应当等于 \(to) 的正文")
        }
    }

    @Test("环形重定向返回空而不是死循环")
    func redirectCyclesTerminate() throws {
        let ring = ["a": "@@@LINK=b", "b": "@@@LINK=c", "c": "@@@LINK=a"]
        #expect(try DictIndex.resolveRedirect("@@@LINK=a") { ring[$0] } == nil)
        // 断链同样返回 nil，不能把 "@@@LINK=…" 本身当正文吐出去。
        #expect(try DictIndex.resolveRedirect("@@@LINK=nowhere") { _ in nil } == nil)
    }

    @Test("元数据键的判定：词表参数和附录页算，at 符号词条不算")
    func metaKeyPredicate() {
        #expect(KeyTable.isMetaKey("@topic_animals_level=a1"))
        #expect(KeyTable.isMetaKey("@wordlists_opal_dataset=english&list=opal_spoken&level=sublist_1"))
        #expect(KeyTable.isMetaKey("oalecd_ref_CEFR"))
        #expect(!KeyTable.isMetaKey("@"), "@ 是 at 符号的正经词条（@@@LINK=at）")
        #expect(!KeyTable.isMetaKey("topic"))
        #expect(!KeyTable.isMetaKey("wordlist"))
        #expect(!KeyTable.isMetaKey("cefr"))
    }

    @Test("候选不再被元数据键刷屏")
    func suggestionsFilterMetaKeys() throws {
        // 实测这三个查询原来分别刷出 24 / 457 / 1 条元数据键。
        guard let table = try Self.table(for: GoldenTests.goldens.dictionaries[0]) else { return }
        for query in ["wordlist", "topic", "cefr"] {
            let keys = table.suggestions(query).map { table.dictionary.key(at: $0) }
            #expect(!keys.isEmpty, "\(query) 该有正经候选")
            #expect(keys.allSatisfy { !KeyTable.isMetaKey($0) }, "\(query) → \(keys)")
        }
    }
}
