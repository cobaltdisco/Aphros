import Foundation
import Testing
@testable import DictCore

/// 历史 / 收藏的语义（用户逐条拍过板的）。fileURL 可注入，每个用例一个临时文件。
@MainActor
struct HistoryStoreTests {

    private func makeStore() -> (store: HistoryStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "history-test-\(UUID().uuidString).json")
        return (HistoryStore(fileURL: url), url)
    }

    @Test func 重复查询上移不新增() {
        let (store, _) = makeStore()
        store.recordOpen("apple", preview: nil)
        store.recordOpen("bank", preview: nil)
        store.recordOpen("apple", preview: "苹果")
        #expect(store.entries.map(\.word) == ["apple", "bank"])
        #expect(store.entries.first?.preview == "苹果")    // 预览有新值就更新
    }

    @Test func 收藏是记录上的标志() {
        let (store, _) = makeStore()
        store.recordOpen("apple", preview: nil)
        #expect(store.toggleFavorite("apple") == true)
        #expect(store.isFavorite("apple"))
        #expect(store.favorites.map(\.word) == ["apple"])
        #expect(store.toggleFavorite("apple") == false)
        #expect(store.favorites.isEmpty)
        // 没打开过的词直接收藏：补一条记录（正常路径到不了，但不能崩）
        #expect(store.toggleFavorite("ghost") == true)
        #expect(store.entries.map(\.word).contains("ghost"))
    }

    @Test func 删除的是记录本身收藏跟着走() {
        let (store, _) = makeStore()
        store.recordOpen("apple", preview: nil)
        store.toggleFavorite("apple")
        store.remove("apple")
        #expect(store.entries.isEmpty)
        #expect(store.favorites.isEmpty)
        #expect(store.isFavorite("apple") == false)
    }

    @Test func 落盘可回读() {
        let (store, url) = makeStore()
        store.recordOpen("apple", preview: "苹果")
        store.toggleFavorite("apple")
        let reloaded = HistoryStore(fileURL: url)
        #expect(reloaded.entries.count == 1)
        #expect(reloaded.entries.first?.favorite == true)
        #expect(reloaded.entries.first?.preview == "苹果")
    }
}
