import Foundation
import Observation

/// 历史 + 收藏。首页的数据源。
///
/// 一个 JSON 文件存全部记录——纯自用，量级撑死几千条，一次全量读写比
/// SwiftData / 增量落盘都简单，坏了删文件重来。收藏不是单独一张表，
/// 就是记录上的一个标志：能收藏的词一定先被打开过（星在词条页里），
/// 所以「收藏 ⊆ 历史」天然成立，首页的过滤只是个 filter。
///
/// 排序即数组顺序：最近打开的在前。重复查询把旧记录上移到顶、不新增
/// （用户定的），收藏标志和预览跟着记录走。
@MainActor @Observable
public final class HistoryStore {

    public struct Entry: Codable, Identifiable {
        public var word: String
        /// 第一条释义的中文（EntryRenderer.preview）。打开词条时抓一次存起来，
        /// 首页每行的小字不用回词典里现查。
        public var preview: String?
        public var favorite = false
        public var openedAt: Date
        public var id: String { word }
    }

    public private(set) var entries: [Entry] = []

    public var favorites: [Entry] { entries.filter(\.favorite) }

    private let fileURL: URL

    /// 默认落在 Application Support（macOS 是它的 Dict 子目录，见 AppPaths）——
    /// Documents 对这个 App 是词典文件的地盘（文件共享开着，用户会在「文件」里翻），
    /// 历史不该混在那里面。
    public init(fileURL: URL? = nil) {
        let url = fileURL ?? URL.dictSupportDirectory.appending(path: "history.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let stored = try? Self.decoder.decode([Entry].self, from: data) {
            entries = stored
        }
    }

    // MARK: 变更

    /// 打开了一个词。已有记录上移到顶；预览有新值就更新（词典换了版本预览会变）。
    public func recordOpen(_ word: String, preview: String?) {
        var entry = entries.first { $0.word == word }
            ?? Entry(word: word, preview: preview, openedAt: .now)
        entry.openedAt = .now
        if let preview { entry.preview = preview }
        entries.removeAll { $0.word == word }
        entries.insert(entry, at: 0)
        save()
    }

    /// 翻转收藏，返回新状态（词条页拿它去切星的实心/空心）。
    /// 星只在词条页上，正常路径词一定已在历史里；万一不在就补一条。
    @discardableResult
    public func toggleFavorite(_ word: String, preview: String? = nil) -> Bool {
        if let i = entries.firstIndex(where: { $0.word == word }) {
            entries[i].favorite.toggle()
            save()
            return entries[i].favorite
        }
        entries.insert(Entry(word: word, preview: preview, favorite: true, openedAt: .now), at: 0)
        save()
        return true
    }

    public func isFavorite(_ word: String) -> Bool {
        entries.first { $0.word == word }?.favorite ?? false
    }

    /// 删除一条记录。删的是**记录本身**，收藏标志跟着记录走（「收藏 ⊆ 历史」，
    /// 见类注释）——在只看收藏的过滤下删，也是同一个语义。
    public func remove(_ word: String) {
        entries.removeAll { $0.word == word }
        save()
    }

    // MARK: 落盘

    /// 每次变更全量写。实测方向：几千条 JSON 是几百 KB 的量级，主线程原子写
    /// 一次远在一帧以内；等它真成了问题再谈防抖。
    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 日期用 ISO 8601 存——这个文件是要拿眼睛看、拿别的工具读的（纯自用的
    /// 好处），时间戳存浮点数就没法看了。
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
