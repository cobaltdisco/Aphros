import Foundation
import Testing
@testable import DictCore

/// 查词策略（DictionaryStore.resolve）——三个壳层共用的唯一入口。
/// 用例就是 2026-08-30/31 真踩过的坑：Full/full 裂两条、gave 停在桥上、
/// 划词带标点查不到。依赖真实词典，本地没有 dicts/ 时整组跳过（同引擎测试）。
@MainActor
struct DictionaryStoreTests {

    nonisolated static let dictionaries = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "dicts/oalecd_10_refined")

    nonisolated static var hasDictionary: Bool {
        FileManager.default.fileExists(atPath: dictionaries.appending(path: "oaldpe.mdx").path)
    }

    private func loadedStore() async throws -> DictionaryStore {
        let store = DictionaryStore(dictionariesRoot: Self.dictionaries)
        await store.load()
        guard case .ready = store.phase else { throw NotReady(phase: String(describing: store.phase)) }
        return store
    }
    struct NotReady: Error { let phase: String }

    @Test(.enabled(if: hasDictionary, "本地没有 dicts/，跳过"))
    func 键入路径规范词头且不跟桥() async throws {
        let store = try await loadedStore()
        #expect(store.resolve(typed: "Full") == "full")       // 大小写以词典键为准
        #expect(store.resolve(typed: " full \n") == "full")   // 只修空白
        #expect(store.resolve(typed: "gave") == "gave")       // 键入 gave 就看 gave
        #expect(store.resolve(typed: "   ") == nil)
        #expect(store.resolve(typed: "zzzzqx") == nil)
    }

    @Test(.enabled(if: hasDictionary, "本地没有 dicts/，跳过"))
    func 划词路径归一化并跟桥() async throws {
        let store = try await loadedStore()
        #expect(store.resolve(selection: "gave") == "give")       // 纯桥条目跟一跳
        #expect(store.resolve(selection: "“word”") == "word")     // 划进来的弯引号
        #expect(store.resolve(selection: "word’s") == "word")     // 所有格
        #expect(store.resolve(selection: "Running") == "running") // 原样优先，不被 run 抢先
        #expect(store.resolve(selection: "zzzzqx") == nil)
    }

    @Test(.enabled(if: hasDictionary, "本地没有 dicts/，跳过"))
    func 浮窗版式的根类() async throws {
        let store = try await loadedStore()
        let glean = try #require(store.document(for: "glean", panel: true))
        #expect(glean.contains(" panel"))
        #expect(!glean.contains(" n2"))          // 单义项：号列不放宽
        let run = try #require(store.document(for: "run", panel: true))
        #expect(run.contains(" n2"))             // 63 个义项：两位数号列
        let window = try #require(store.document(for: "glean"))
        #expect(!window.contains(" panel"))      // 主窗口不带浮窗类
    }

    @Test func 空文档可用() {
        #expect(DictionaryStore.emptyDocument.contains("<html"))
        #expect(DictionaryStore.emptyDocument.contains("entry.css"))
    }
}
