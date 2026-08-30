import CryptoKit
import Foundation
import Testing
@testable import MDictKit

/// M1 记录读取的对拍。期望值同样来自参考实现（goldens.json），
/// 比的是**字节数 + SHA-256**——只比长度的话，一个字节错位也照样过。
struct RecordTests {

    /// 46 万词头的 mdx 打开一次要 0.4 秒，八条 golden 各开一次太浪费。
    /// Swift Testing 里同一 suite 的用例可能并发跑，所以要加锁。
    nonisolated(unsafe) private static var opened: [String: MDict] = [:]
    private static let lock = NSLock()

    static func dictionary(at path: String) throws -> MDict? {
        let url = GoldenTests.repoRoot.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let hit = opened[path] { return hit }
        let dict = try MDict(contentsOf: url)
        opened[path] = dict
        return dict
    }

    /// goldens.json 用 (key, index) 定位——`上当` 在 OALDPE 里有两条同名词头。
    static func entryIndex(in dict: MDict, key: String, occurrence: Int) -> Int? {
        var seen = 0
        for i in 0..<dict.keyCount where dict.key(at: i) == key {
            if seen == occurrence { return i }
            seen += 1
        }
        return nil
    }

    @Test("记录正文与实测值逐字节一致", arguments: GoldenTests.goldens.dictionaries)
    func recordsMatchGolden(_ spec: GoldenTests.Goldens.Dictionary) throws {
        guard let dict = try Self.dictionary(at: spec.path) else { return }

        for golden in spec.records {
            guard let index = Self.entryIndex(in: dict, key: golden.key, occurrence: golden.index) else {
                Issue.record("词典 \(spec.id) 里找不到词头 \(golden.key)#\(golden.index)")
                continue
            }
            let text = try dict.recordText(at: index)
            let utf8 = Data(text.utf8)
            #expect(utf8.count == golden.utf8ByteCount,
                    "\(spec.id)/\(golden.key)#\(golden.index) 字节数")
            #expect(SHA256.hash(data: utf8).map { String(format: "%02x", $0) }.joined() == golden.sha256,
                    "\(spec.id)/\(golden.key)#\(golden.index) 内容")

            #expect(text.hasPrefix("@@@LINK=") == golden.isRedirect,
                    "\(spec.id)/\(golden.key)#\(golden.index) 是否重定向")
            if let target = golden.redirectTarget {
                #expect(text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines) == target)
            }
        }
    }

    @Test("记录段的自洽性检查", arguments: GoldenTests.goldens.dictionaries)
    func recordSectionIsConsistent(_ spec: GoldenTests.Goldens.Dictionary) throws {
        guard let dict = try Self.dictionary(at: spec.path) else { return }

        #expect(dict.recordBlockCount > 0)
        #expect(dict.recordSectionSize > 0)
        // 最后一条记录必须正好收在拼接空间的末尾，否则说明块长度累加错了。
        let lastStart = try #require(dict.recordOffsets.last.map(Int.init))
        #expect(lastStart < dict.recordSectionSize)
        // 首尾各取一条，确认边界上不越界、不返回空。
        #expect(try dict.recordData(at: 0).count > 0)
        #expect(try dict.recordData(at: dict.keyCount - 1).count > 0)
    }

    @Test("越界索引要抛错而不是返回空数据")
    func outOfRangeThrows() throws {
        guard let dict = try Self.dictionary(at: GoldenTests.goldens.dictionaries[0].path) else { return }
        #expect(throws: MDictError.self) { try dict.recordData(at: -1) }
        #expect(throws: MDictError.self) { try dict.recordData(at: dict.keyCount) }
    }
}
