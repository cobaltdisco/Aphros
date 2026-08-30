import CryptoKit
import DictIndex
@testable import DictRender
import Foundation
import Testing
@testable import MDictKit

/// M4 音频资源。这一层守的是 ADR 0002 记的那个失败模式：
/// **返回相邻键的内容**——喇叭照按、声音"像是对的"，UI 上完全无症状。
/// mdict-cpp 就是这么错了 16% 的音频。
struct ResourceTests {

    nonisolated(unsafe) private static var opened: ResourceLibrary?
    private static let lock = NSLock()

    static func library() throws -> ResourceLibrary? {
        let url = GoldenTests.repoRoot.appending(path: "dicts/oalecd_10_refined/oaldpe.1.mdd")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let hit = opened { return hit }
        let lib = ResourceLibrary([try MDict(contentsOf: url)])
        opened = lib
        return lib
    }

    // MARK: 路径归一化

    @Test("引用到 mdd 键的四步归一化")
    func normalization() {
        let n = ResourceLibrary.normalize
        #expect(n("abandon__gb_2.mp3")   == "\\abandon__gb_2.mp3")      // 补前置反斜杠
        #expect(n("_abandon%23_gbs_1.mp3") == "\\_abandon#_gbs_1.mp3")  // urldecode：%23 就是 #
        #expect(n("image/foo.png")      == "\\image\\foo.png")          // 斜杠换向
        #expect(n("\\Already\\Backslashed.MP3") == "\\already\\backslashed.mp3")
        // 顺序不能换：先 urldecode 再换斜杠，否则 %2F 解出来的斜杠不会被处理
        #expect(n("a%2Fb.mp3") == "\\a\\b.mp3")
    }

    // MARK: 不能返回邻居的内容

    @Test("排序上相邻的键各返回各的字节")
    func neighboursDoNotBleed() throws {
        guard let lib = try Self.library() else { return }
        // ADR 0002 里的原样本：mdict-cpp 查 worded__gb_1.mp3 会拿到 word_perfect 的内容。
        let a = try #require(try lib.data(for: "worded__gb_1.mp3"))
        let b = try #require(try lib.data(for: "word_perfect_1_gb_1.mp3"))
        let c = try #require(try lib.data(for: "word__gb_1.mp3"))
        #expect(a.count == 5384)
        #expect(b.count == 7230)
        #expect(c.count == 4474)
        #expect(Set([a, b, c]).count == 3, "三个相邻键返回了相同的内容")
        // 都得是 MP3 帧同步头，返回错东西时这条也会挂
        for d in [a, b, c] { #expect(d.prefix(2) == Data([0xff, 0xfb])) }
    }

    @Test("不存在的键返回 nil，不返回最接近的那个")
    func missingReturnsNil() throws {
        guard let lib = try Self.library() else { return }
        // 排序上正好落在 word__gb_1.mp3 和 word__us_1.mp3 之间
        #expect(try lib.data(for: "word__gb_1x.mp3") == nil)
        // 词典自己缺的文件（实测 1.57% 的引用属于这一类）
        #expect(try lib.data(for: "livestreamer__gb_1.mp3") == nil)
        #expect(lib.contains("livestreamer__gb_1.mp3") == false)
        #expect(lib.contains("abandon__gb_2.mp3") == true)
    }

    @Test("大小写和 URL 编码都不影响命中")
    func lookupIsForgiving() throws {
        guard let lib = try Self.library() else { return }
        let canonical = try #require(try lib.data(for: "abandon__gb_2.mp3"))
        #expect(try lib.data(for: "ABANDON__GB_2.MP3") == canonical)
        #expect(try lib.data(for: "\\abandon__gb_2.mp3") == canonical)
        #expect(try lib.data(for: "abandon__gb_2%2Emp3") == canonical)
    }

    // MARK: 命中率

    @Test("单词发音的整体命中率")
    func hitRate() throws {
        guard let lib = try Self.library(),
              let mdx = try RecordTests.dictionary(at: "dicts/oalecd_10_refined/oaldpe.mdx")
        else { return }

        var word = Set<String>(), sentence = Set<String>()
        for i in stride(from: 0, to: mdx.keyCount, by: max(1, mdx.keyCount / 1200)) {
            let raw = try mdx.recordText(at: i)
            guard !raw.hasPrefix("@@@LINK=") else { continue }
            for r in raw.matches(of: /href="sound:\/\/([^"]+)"/) {
                let s = String(r.1)
                if s.contains("%23") { sentence.insert(s) } else { word.insert(s) }
            }
        }
        let hit = word.count { lib.contains($0) }
        #expect(word.count > 400, "样本太小，说不明问题")
        // 实测 98.43%。掉到 95% 以下说明归一化坏了，不是词典缺文件。
        #expect(hit * 100 / word.count >= 95,
                "单词发音命中 \(hit)/\(word.count)")
        // 例句朗读在 3.mdd 里，本项目不带——应当**一个都命不中**。
        // 如果这条挂了，说明归一化把例句路径错配到单词发音上去了，那是最坏的情况：
        // 点例句喇叭放出来的是别的词的读音。
        #expect(sentence.count { lib.contains($0) } == 0,
                "例句朗读不该在 1.mdd 里命中")
    }

    // MARK: 没有音频的喇叭

    @Test("取不到音频的喇叭要打上标记")
    func missingAudioMarked() {
        let html = #"""
        <a class="sound audio_play_button pron-uk icon-audio" href="sound://have.mp3"></a>\#
        <a class="sound pron-us app" href="sound://missing.mp3"></a>
        """#
        let out = EntryRenderer.markMissingAudio(html) { $0 == "have.mp3" }
        #expect(out.contains(#"<a class="sound audio_play_button pron-uk icon-audio" href="sound://have.mp3""#))
        #expect(out.contains(#"<a class="sound pron-us app noaudio" href="sound://missing.mp3""#))
        #expect(out.ranges(of: "noaudio").count == 1)
    }
}
