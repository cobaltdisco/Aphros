import Foundation
import Testing
@testable import DictIndex
@testable import MDictKit

/// 索引缓存（ADR 0008 附记）：写出再读回必须得到**同一张表**，指纹不符 /
/// 文件损坏必须安静地返回 nil 走重建，绝不能返回错表。
struct IndexCacheTests {

    static func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "index-cache-test-\(UUID().uuidString).didx")
    }

    @Test("缓存不存在 / 内容是垃圾时返回 nil")
    func missingOrGarbage() throws {
        let source = URL(filePath: #filePath)          // 任何存在的文件都行，只做指纹
        #expect(IndexCache.load(source: source, from: Self.temporaryCacheURL()) == nil)

        let garbage = Self.temporaryCacheURL()
        try Data("这不是缓存".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        #expect(IndexCache.load(source: source, from: garbage) == nil)
    }

    @Test("写出读回逐字节一致，查询行为不变；指纹不符与版本不符都拒收")
    func roundTripOnRealDictionary() throws {
        guard let dict = try RecordTests.dictionary(at: "dicts/Oxford Advanced/oxfordadvanced.mdx")
        else { return }
        let source = dict.url
        let fresh = KeyTable(dict)
        let cacheURL = Self.temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        try IndexCache.write(fresh, source: source, to: cacheURL)
        let loaded = try #require(IndexCache.load(source: source, from: cacheURL))

        // 数组逐字节一致
        #expect(loaded.order == fresh.order)
        #expect(loaded.mixedCase == fresh.mixedCase)
        #expect(loaded.dictionary.keyBlob == fresh.dictionary.keyBlob)
        #expect(loaded.dictionary.keyStarts == fresh.dictionary.keyStarts)
        #expect(loaded.dictionary.recordOffsets == fresh.dictionary.recordOffsets)

        // 查询行为一致（走的是缓存里的 order）
        for query in ["abandon", "light", "the", "zz", "不存在的词"] {
            #expect(loaded.exact(query) == fresh.exact(query))
            #expect(loaded.prefix(query, limit: 20) == fresh.prefix(query, limit: 20))
        }
        // 记录索引偏移有效：缓存路径打开的 MDict 能取到和全量路径相同的正文
        let index = fresh.exact("abandon").first ?? 0
        #expect(try loaded.dictionary.recordText(at: index)
                == fresh.dictionary.recordText(at: index))

        // 指纹不符（拿另一个文件当源）→ nil
        let otherSource = URL(filePath: #filePath)
        #expect(IndexCache.load(source: otherSource, from: cacheURL) == nil)

        // 版本号 +1 → nil（升级归一化规则时旧缓存必须整体作废）
        var bytes = try Data(contentsOf: cacheURL)
        bytes[4] &+= 1
        let bumped = Self.temporaryCacheURL()
        try bytes.write(to: bumped)
        defer { try? FileManager.default.removeItem(at: bumped) }
        #expect(IndexCache.load(source: source, from: bumped) == nil)
    }
}
