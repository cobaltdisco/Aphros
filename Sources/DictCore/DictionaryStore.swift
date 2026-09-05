import DictIndex
import DictRender
import Foundation
import MDictKit
import Observation

/// 词典的加载与查询。**界面只跟它打交道**（门面）：视图不 import 引擎三层，
/// 查词策略（resolve）、渲染（document）、发音（play）都从这里要。
@MainActor @Observable
public final class DictionaryStore {

    public enum Phase {
        case loading
        case missing(URL)
        case ready
        case failed(String)
    }

    public private(set) var phase: Phase = .loading
    public private(set) var title = "词典"
    /// 冷启动耗时：mdx 索引就绪（缓存命中是读文件，未中是解压 + 排序 + 写缓存）
    /// 和全部 mdd 的资源库就绪。**显示出来是有意的**——ADR 0008 拿这个数字
    /// 检验索引缓存有没有兑现。
    public private(set) var indexElapsed: Duration = .zero
    public private(set) var resourceElapsed: Duration = .zero
    /// mdx 的索引这次是从缓存读的还是现场重建的（重建 = 首启或词典文件换了）。
    public private(set) var indexFromCache = false

    private var table: KeyTable?
    private var resources = ResourceLibrary([])
    private let audio = AudioPlayer()

    public var keyCount: Int { table?.dictionary.keyCount ?? 0 }
    public var resourceCount: Int { resources.resourceCount }

    /// 词典根目录。默认是双端约定的落点（AppPaths）；测试注入仓库里的 dicts/。
    private let dictionariesRoot: URL

    public init(dictionariesRoot: URL = .dictionariesRoot) {
        self.dictionariesRoot = dictionariesRoot
    }

    // MARK: 加载

    public func load() async {
        let documents = dictionariesRoot
        #if os(macOS)
        // 目录先立起来，「没有词典」页才能指着一个真实存在的文件夹说「放这里」。
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        #endif
        guard let mdx = Self.findMDX(in: documents) else { phase = .missing(documents); return }

        do {
            let clock = ContinuousClock()
            // 46 万词头解压 + 排序，主线程干这个会卡住启动动画。
            let mdds = Self.findMDDs(besides: mdx)
            let built = try await Task.detached(priority: .userInitiated) {
                // 索引缓存（ADR 0008 附记，2026-08-25 拍板落地）：命中就跳过
                // 键区块解压和全量排序；源文件换了指纹（大小 + 修改时间）对不上，
                // **自动**重建并重写缓存，用户不需要做任何事，只是那一次启动慢。
                // 每部（mdx + 各 mdd）一个缓存文件，跟着源文件名走。
                func cachedTable(for source: URL) throws -> (table: KeyTable, hit: Bool) {
                    let cacheURL = URL.dictSupportDirectory
                        .appending(path: "index-cache/\(source.lastPathComponent).didx")
                    if let cached = IndexCache.load(source: source, from: cacheURL) {
                        return (cached, true)
                    }
                    let fresh = KeyTable(try MDict(contentsOf: source))
                    // 写失败只是下次照样重建，不值得让启动失败。
                    try? IndexCache.write(fresh, source: source, to: cacheURL)
                    return (fresh, false)
                }

                var indexTime = Duration.zero, resourceTime = Duration.zero
                var main: (table: KeyTable, hit: Bool)!
                indexTime = try clock.measure { main = try cachedTable(for: mdx) }
                // 资源库和正文一起在后台建。oaldpe.1.mdd 是 1.1 GB，但只读键索引。
                var library = ResourceLibrary([])
                resourceTime = clock.measure {
                    library = ResourceLibrary(tables: mdds.compactMap {
                        (try? cachedTable(for: $0))?.table
                    })
                }
                return Built(table: main.table, fromCache: main.hit, resources: library,
                             index: indexTime, resource: resourceTime)
            }.value

            table = built.table
            resources = built.resources
            indexElapsed = built.index
            resourceElapsed = built.resource
            indexFromCache = built.fromCache
            title = built.table.dictionary.header.title ?? mdx.deletingPathExtension().lastPathComponent
            phase = .ready
            // 冷启动耗时也打到 stdout：真机上没法截屏看开屏页，
            // `devicectl device process launch --console` 能直接收到这一行。
            print("[startup] 索引 \(built.index)（\(built.fromCache ? "缓存" : "重建")） · 资源 \(built.resource) · 词头 \(built.table.dictionary.keyCount)")
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private struct Built: Sendable {
        let table: KeyTable
        let fromCache: Bool
        let resources: ResourceLibrary
        let index: Duration
        let resource: Duration
    }

    /// 和 mdx 同目录的全部 .mdd。按文件名排序，保证多部之间的优先级是确定的。
    private static func findMDDs(besides mdx: URL) -> [URL] {
        let directory = mdx.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
        return names.filter { $0.lowercased().hasSuffix(".mdd") }
            .sorted()
            .map { directory.appending(path: $0) }
    }

    /// Documents 底下**任意深度**的第一个 .mdx。
    ///
    /// 不要求放进某个特定子目录：从 Finder 拖是散文件，从「文件」App 拖常常是
    /// 一整个词典文件夹，两种都得认。「该放哪儿」不该是个需要看文档才知道的问题。
    /// 同名排序取第一个，保证多部词典时选择是确定的。
    private static func findMDX(in directory: URL) -> URL? {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: directory.path())
        else { return nil }
        return paths.filter { $0.lowercased().hasSuffix(".mdx") }
            .sorted()
            .first
            .map { directory.appending(path: $0) }
    }

    // MARK: 查询

    public struct Suggestion: Identifiable, Hashable {
        public let id: Int
        public let key: String
    }

    /// 搜索建议。**同名词头合并成一行**——`light bulb` 在 OALDPE 里有两条
    /// （一条重定向到 bulb，一条到 light-bulb），列两行一模一样的字给不了任何信息。
    /// 点开时 `document(for:)` 会把同名的全部拼进同一页，一条都不丢。
    public func suggestions(for query: String, limit: Int = 40) -> [Suggestion] {
        guard let table, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var seen = Set<String>()
        return table.suggestions(query, limit: limit * 2)
            .map { Suggestion(id: $0, key: table.dictionary.key(at: $0)) }
            .filter { seen.insert($0.key).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// 查到的正文，已经变换 + 包成完整文档。同名词头有多条时全部拼在一页里。
    /// `favorited` 变成根元素上的 `faved` 类——词头行那颗星是实心还是空心。
    public func document(for query: String, favorited: Bool = false, panel: Bool = false) -> String? {
        let body: String
        if let cached = bodyCache[query] {
            body = cached
        } else {
            guard let table, let matches = try? table.lookup(query), !matches.isEmpty
            else { return nil }
            body = matches
                .map { EntryRenderer.transform($0.html) }
                .map { resources.isEmpty ? $0 : EntryRenderer.markMissingAudio($0) { resources.contains($0) } }
                .joined()
            bodyCache[query] = body
            bodyCacheOrder.append(query)
            if bodyCacheOrder.count > 16 {
                bodyCache.removeValue(forKey: bodyCacheOrder.removeFirst())
            }
        }
        var classes = Self.rootClasses(favorited: favorited, panel: panel)
        // 浮窗的义项号沟宽自适应（entry.css 的 n2 段）：任何一节义项到两位数
        // 就恢复两位宽的号列。数的是整页 li_sense_before 出现次数——多词性
        // 词条各节计数会虚高（verb 6 + noun 5 = 11，实际最大号只有 6），
        // 虚高的代价只是沟宽回到老值，不算错版。
        if panel, body.components(separatedBy: "li_sense_before").count - 1 >= 10 {
            classes.append("n2")
        }
        return EntryRenderer.document(preTransformedBody: body, extraRootClasses: classes)
    }

    /// 空文档：WebView 预热用（词典一就绪就装上，把 WebContent 进程和样式表
    /// 热好，第一个词免掉冷启动白屏）。放这里而不是让视图自己拼——视图
    /// 不该 import 渲染层，「界面只跟 store 打交道」这条线要靠编译器守。
    public nonisolated static let emptyDocument = EntryRenderer.document(
        preTransformedBody: "", extraRootClasses: rootClasses())

    /// 文档外壳上的界面状态类。`mac` 是 macOS 版心开关（entry.css 末节）：
    /// 窗口没有安全区和底部玻璃条，行宽还得封顶，让位规则整套换掉。
    /// `panel` 是划词浮窗的窄版心（ADR 0011 预留的「加一个类即可」，2026-08-30 兑现）。
    public nonisolated static func rootClasses(favorited: Bool = false, panel: Bool = false) -> [String] {
        var classes = favorited ? ["faved"] : []
        #if os(macOS)
        classes.append("mac")
        if panel { classes.append("panel") }
        #endif
        return classes
    }

    /// 变换后的正文缓存。同一个词再点开（历史页、词条里内链跳走又跳回）不付
    /// 第二遍变换的钱——大词条一遍 70–100 ms（实测 light / go，模拟器），
    /// 而且是在主线程上、顶着点按动画的起步。存**正文**不存整份文档：收藏态
    /// 是文档外壳上的根类，进了键的话收藏一下缓存就全废。
    /// 16 份按最大词条算 ~3 MB，FIFO 淘汰就够，不值得上 LRU。
    private var bodyCache: [String: String] = [:]
    private var bodyCacheOrder: [String] = []

    /// 候选行和历史记录里那行中文预览。带缓存——同一个词在候选里会反复出现，
    /// 而一次抽取要解压一整个记录块（实测均 0.12–0.42 ms，缓存后为零）。
    /// 抽不到的也缓存（存空串），免得每次滚过都白查一遍。
    private var previewCache: [String: String] = [:]

    // MARK: 查词策略

    /// 「用户给的文本 → 该打开的词」这一步**只住在这里**（2026-08-31 收编）：
    /// 之前浮窗和两个主窗口各写一版，Mac 加了规范词头 iOS 没跟上，Full/full
    /// 在 iOS 上还裂成两条历史——策略散落的账。三个壳层拿到词后再各自要
    /// 文档、各自决定记不记历史（那是界面的事，有意留在壳层）。
    ///
    /// 键入路径：原样查（只修空白），命中后换成规范词头。**不跟桥**——
    /// 键入 gave 是明确要看 gave，桥上那句「past tense of give」就是答案。
    public func resolve(typed query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return canonicalKey(for: trimmed)
    }

    /// 划词路径：归一化候选逐试（标点/所有格/屈折短语，QueryNormalizer 有
    /// 实测依据）→ 命中纯桥条目就跟着词典自己的 entry:// 箭头跳一步
    ///（gave 的正文只有一句 past tense of give，浮窗要的是终点释义）→ 规范词头。
    public func resolve(selection raw: String) -> String? {
        for candidate in QueryNormalizer.candidates(for: raw) {
            guard let table, let match = try? table.lookup(candidate).first else { continue }
            let target = EntryRenderer.bridgeTarget(for: match.html) ?? candidate
            if let word = canonicalKey(for: target) { return word }
        }
        return nil
    }

    /// 划中文本的**展示形**：剥掉首尾标点/弯引号后的原文（归一化链的第一个
    /// 候选），查不到时浮窗拿它显示「没有找到 “xxx”」、喂给「在 Aphros 中打开」。
    /// 纯标点/空白返回 nil。放这里是为了让壳层不必 import 引擎层。
    public nonisolated static func displayForm(ofSelection raw: String) -> String? {
        QueryNormalizer.candidates(for: raw).first
    }

    /// 查询对应的**词典规范词头**：Full → full。历史和收藏用它作键
    ///（2026-08-30 用户拍板：Full 和 full 不该是两条记录）——大小写以词典
    /// 为准而不是无脑小写：换一部保留专名大写的词典也不会把 Monday 毁成
    /// monday（OALDPE 键表实测本来就全小写，效果一样）。exact() 本来就大小写
    /// 折叠，这里只是把折叠后命中的原样键拿出来当身份。
    private func canonicalKey(for query: String) -> String? {
        guard let table, let match = try? table.lookup(query).first else { return nil }
        return match.key
    }

    public func preview(for key: String) -> String? {
        if let cached = previewCache[key] { return cached.isEmpty ? nil : cached }
        let preview = (try? table?.lookup(key).first)
            .flatMap { $0 }
            .flatMap { EntryRenderer.preview(for: $0.html) }
        previewCache[key] = preview ?? ""
        return preview
    }

    // MARK: 内存警告

    /// 把能重建的全清掉：解压区块缓存（mdx + 各 mdd，上限 8 MB × 卷数）、
    /// 渲染缓存、预览缓存。索引不动——重建索引等于重启。
    /// `MDict.purgeCache()` 之前一直是死代码，没有任何调用方；挂到这儿才算闭环。
    public func didReceiveMemoryWarning() {
        table?.dictionary.purgeCache()
        resources.purgeCaches()
        previewCache.removeAll()
        bodyCache.removeAll()
        bodyCacheOrder.removeAll()
    }

    // MARK: 发音

    /// 播 `sound://xxx.mp3` 指的那段音频。取不到就什么都不做——
    /// 取不到的喇叭在渲染时已经藏掉了，走到这里说明资源库还没建好。
    public func play(sound reference: String) {
        guard let data = try? resources.data(for: reference), !data.isEmpty else { return }
        audio.play(data, reference: reference)
    }
}
