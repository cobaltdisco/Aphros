import AppKit
import DictCore
import SwiftUI

/// Mac 主界面：双栏（ADR 0011 方向一，「书桌上的词典」）。
///
///     边栏（搜索框 + 一栏三态：历史 / 候选 / 收藏） | 词条（WebView 常驻）
///
/// iOS 的三层一栈在这里摊平成一栏：没有转场、没有返回手势，「来处」永远可见。
/// WebView 沿用 iOS 的策略：词典一就绪就建、从生到死只挂一次，换词只换文档
/// ——正文 HTML 和 iOS 逐字节相同，只在根元素上多一个 mac 版心类。
struct MacRootView: View {
    /// App 层持有传进来（见 DictMacApp）——取词浮窗共用同一份。
    let store: DictionaryStore
    let history: HistoryStore
    /// 浮窗 / 菜单栏对主窗口的请求从这里来（pendingRequest，单通道，见 LookupRuntime）。
    let runtime: LookupRuntime

    @State private var query = ""
    /// 候选缓存在状态里不做计算属性，理由同 iOS RootView：body 里访问几十次，
    /// 每次都重跑搜索的话界面忙到吃不下点击。
    @State private var suggestions: [DictionaryStore.Suggestion] = []
    @State private var document: String?
    @State private var openedWord: String?
    @State private var showFavoritesOnly = false
    /// 边栏列表的选中词。**选中即打开**（系统词典 App 的手感）：↑↓ 扫过候选，
    /// 右栏跟着换——大词条一次变换 70–100 ms 且有 16 份缓存，扫起来跟得上。
    @State private var selection: String?
    @FocusState private var searchFocused: Bool
    /// 列表键控（↑↓⌫）的事件监视器，见 body 末尾的 onAppear。
    @State private var listKeyMonitor: Any?
    /// 每回到一次欢迎页加一，边栏列表盯它滚回顶部（最新一条记录）。
    @State private var welcomeResets = 0
    /// 浮窗带词进来时要选中的词。搜索框一换内容 onChange 就把选中清掉
    ///（打字时该这样），所以「进来即选中」得等那一步跑完再落，见 onChange(query)。
    @State private var selectAfterQueryChange: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        // 标题整个不要（用户拍板，两轮：先去掉当前词——和正文词头同屏重复；
        // 再去掉「词典」——渲染图的详情区顶部就是空的）。窗口在切换器里显示
        // App 名，不受影响。
        .navigationTitle("")
        .tint(.accent)
        .onChange(of: query) { _, new in
            suggestions = store.suggestions(for: new)
            // 打字时清掉旧选中；浮窗带词进来时改成选中那个词（它一定在
            // 候选里：规范词头前缀搜自己必中），随后 onChange(selection) 打开它。
            selection = selectAfterQueryChange
            selectAfterQueryChange = nil
        }
        .onChange(of: selection) { _, new in
            guard let word = new else { return }
            // 从历史/收藏点开**不** recordOpen：「重复查询上移」会让正在 ↑↓
            // 逐行浏览的列表当场重排，选中行跳来跳去。上移只对搜索路径成立
            // ——那时边栏显示的是候选，历史怎么排看不见。
            open(word, record: !suggestions.isEmpty)
        }
        // 浮窗「在 Aphros 中打开」/ 菜单栏「打开 Aphros」：盯 Runtime 的
        // pendingRequest。窗口活着时属性变化触发；窗口重建时 initial: true 在
        // 出现那一刻触发；词典还没就绪就等 phase 翻到 ready 再取。
        .onChange(of: runtime.pendingRequest, initial: true) { _, _ in consumePendingRequest() }
        .onChange(of: isReady) { _, _ in consumePendingRequest() }
        // 列表键控三件套：↑↓ 挪选中、⌫ 删记录（2026-08-30 用户拍板）。
        // 全走本地键码监视器不走 onKeyPress——后者只在搜索框聚焦时生效
        //（TextField 的 field editor 还会吞 ⌫），点过列表行焦点一丢键就哑。
        // 键码是硬件码（125↓ 126↑ 51⌫），布局无关；裸按、事件属于主窗口
        //（浮窗是 NSPanel 不掺和）、且动作真发生了才吞事件，
        // 其余情况原样放行——框里打字删字不受影响。
        .onAppear {
            guard listKeyMonitor == nil else { return }
            listKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let window = event.window, !(window is NSPanel),
                      // 输入法正在组字（拼音字母还在组字区、没进搜索框，
                      // query 仍是空的）时三个键全部放行：⌫ 该删字母不是删
                      // 记录，↑↓ 该翻候选（2026-09-05 用户报的 ⌫ 那半）。
                      !((window.firstResponder as? NSTextView)?.hasMarkedText() ?? false)
                else { return event }
                let handled = switch event.keyCode {
                case 125: move(1)
                case 126: move(-1)
                case 51:  deleteSelectedRecord()
                default:  false
                }
                return handled ? nil : event
            }
        }
        .onDisappear {
            if let listKeyMonitor { NSEvent.removeMonitor(listKeyMonitor) }
            listKeyMonitor = nil
        }
    }

    private var isReady: Bool {
        if case .ready = store.phase { return true }
        return false
    }

    private func consumePendingRequest() {
        guard isReady, let request = runtime.pendingRequest else { return }
        runtime.pendingRequest = nil
        switch request {
        case .word(let word):
            // 进来即选中那个词（2026-09-05 用户报：边栏原本选着别的词时，
            // 正文换了、高亮还停在旧词上）。走 selection → open 这条正路，
            // 顺带滚动到它；浮窗已记过历史，这里再记一次只是同词置顶，无害。
            if query == word {
                selection = word        // 搜索框没变 onChange 不会跑，直接选
            } else {
                selectAfterQueryChange = word
                query = word
            }
        case .welcome:
            showWelcome()
        }
    }

    /// 回到刚启动的样子：空搜索框、欢迎页、历史列表（不筛收藏）滚回最新一条。
    /// 关窗只是隐藏不销毁，不主动清这些状态就还是关窗前那一刻。
    private func showWelcome() {
        query = ""
        suggestions = []
        selection = nil
        document = nil
        openedWord = nil
        showFavoritesOnly = false
        welcomeResets += 1
    }

    // MARK: 边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 过滤钮和搜索框同一行——iOS 上用户定的位置（和搜索胶囊一行），
            // Mac 照搬。曾经做成搜索框下方的分段控件（渲染图的画法）：
            // 横在搜索框和列表中间一条硬 chrome，还随状态出现消失，突兀（用户报的）。
            HStack(spacing: 8) {
                searchField
                if showsFilter {
                    filterButton
                }
            }
            .animation(.snappy, value: showsFilter)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            sidebarList
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .background { focusShortcut }
    }

    /// 全部 ↔ 只看收藏。图标语言和 iOS 的过滤钮一致：漏斗 = 看全部中，
    /// 实心黄星 = 只看收藏中。
    private var filterButton: some View {
        Button {
            withAnimation(.snappy) { showFavoritesOnly.toggle() }
        } label: {
            Image(systemName: showFavoritesOnly ? "star.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(showFavoritesOnly ? Color.fav : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(showFavoritesOnly ? "显示全部" : "只看收藏")
        .accessibilityLabel(showFavoritesOnly ? "显示全部" : "只看收藏")
    }

    /// 对齐定稿「一条墨线」：边栏只有一条文本轴，落在 40px——
    /// 12（外衬）+ 8（框内衬）+ 14（放大镜列）+ 6（间距）。搜索框文字、
    /// 列表行词头、空态提示全在这条轴上；放大镜挂轴左，和词条区义项号
    /// 悬挂进沟是同一个关系。改任何一段内衬都要重算这条轴。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField("查询单词", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { submit() }
                // ↑↓ 不在这儿接：onKeyPress 只在框聚焦时生效，点过列表行焦点
                // 就丢了（⌫ 灵、↑↓ 哑，用户报的）。和 ⌫ 一起走下面的键码
                // 监视器，三个键统一不挑焦点。
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            // ⌘F 角标和 ✕ 装进同一个定宽槽、贴右缘：两者天然不同宽，
            // 不锁槽宽的话二者切换时右侧参差（对齐盘点里的第三条）。
            Group {
                if query.isEmpty {
                    // ⌘F 角标（渲染图定的）：空闲时提示快捷键，打字后让位给 ✕。
                    Text("⌘F")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        }
                } else {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空")
                }
            }
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // 渲染图的画法：正文底色的实底 + 发丝描边，浮在半透明的边栏材质上；
        // 系统的 .quinary 灰底和渲染图对不上。
        .background(Color.page, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }

    /// ⌘F 聚焦搜索。藏一颗零尺寸按钮只为挂快捷键——App 级 Commands 要配
    /// FocusedValue 整套管线，为一个快捷键不值。
    private var focusShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// 列表自绘不用 List：系统 List 的选中高亮在列表失焦时是灰的（焦点通常
    /// 在搜索框或正文上，也就是**几乎永远是灰的**），和渲染图的强调色选中对
    /// 不上。自绘行 + 自绘选中（渲染图的 10% 强调底 + 强调色词头），焦点在
    /// 哪儿都长一个样。↑↓ 走 onKeyPress 挪 selection，滚动跟随靠 scrollTo。
    @ViewBuilder
    private var sidebarList: some View {
        let items = listItems
        if items.isEmpty {
            if !query.isEmpty {
                // 三条空态提示全部居中（搜索无果 2026-08-30 拍板、闲置态
                // 2026-08-31 跟上，ADR 0012 附记）：40px 的轴只管有内容的列表。
                Text("没有找到单词")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyHint
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.word) { item in
                            Button { selection = item.word } label: { row(item) }
                                // 不用 .plain：它在鼠标按下瞬间把 label 压暗
                                // 再弹回，点谁谁闪一下（用户报的）。选中态
                                //（强调底 + 强调色）本身就是反馈，按压反馈多余。
                                .buttonStyle(RowButtonStyle())
                                .id(item.word)
                                // 删除特效的一半：被删的行向左滑出 + 淡出；
                                // 另一半（下方行合拢上移）由 withAnimation 驱动。
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                    // 12 和搜索框的外衬一致：选中行的底色盒和搜索框的框
                    // 左右缘共线，行内文本再缩进到 40px 的轴上。
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .onChange(of: selection) { _, new in
                    if let new { proxy.scrollTo(new) }
                }
                .onChange(of: welcomeResets) { _, _ in
                    if let first = items.first { proxy.scrollTo(first.word, anchor: .top) }
                }
            }
        }
    }

    /// 行样式照渲染图：词 medium、预览小字从属；选中行 10% 强调底 + 强调色
    /// 词头。曾经选中还加粗到 semibold——底色和强调色已是两重标记，第三重
    /// 冗余，而且字重一变词宽微跳，↑↓ 扫列表时行行都在抖（用户拍掉的）。
    private func row(_ item: (word: String, preview: String?)) -> some View {
        let selected = selection == item.word
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.word)
                .fontWeight(.medium)
                .foregroundStyle(selected ? Color.accent : Color.primary)
                .lineLimit(1)
            if let preview = item.preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 28 = 轴（40）− 外衬（12）：行文本和搜索框文字同一条轴。
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(selected ? Color.accent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(.rect)
    }

    /// 列表行按钮：零按压反馈（见调用处注释）。
    private struct RowButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    /// 闲置态提示。居中（2026-08-31 用户拍板，和「没有找到单词」同治）——
    /// ADR 0012 曾把它算进 40px 的轴，但空荡荡的面板里一句孤零零的靠左小字
    /// 读起来像掉了对齐，轴的意义只有列表有内容时才成立。
    private var emptyHint: some View {
        Group {
            if showFavoritesOnly {
                Text("词条页词头右边的星\n点一下就收进这里")
            } else {
                Text("查过的词会记在这里")
            }
        }
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }

    /// 一栏三态的数据源：打字时是候选（带同步预览，单条 0.12–0.42 ms 有缓存），
    /// 空搜索时是历史或收藏。
    private var listItems: [(word: String, preview: String?)] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return suggestions.map { ($0.key, store.preview(for: $0.key)) }
        }
        let entries = showFavoritesOnly ? history.favorites : history.entries
        return entries.map { ($0.word, $0.preview) }
    }

    private var showsFilter: Bool {
        guard case .ready = store.phase else { return false }
        return query.isEmpty && !history.entries.isEmpty
    }

    // MARK: 词条（右栏）

    @ViewBuilder
    private var detail: some View {
        switch store.phase {
        case .loading:
            ProgressView("正在建索引…")

        case .missing(let directory):
            ContentUnavailableView {
                Label("还没有词典", systemImage: "book.closed")
            } description: {
                Text("把 .mdx 和 .mdd 放进 \(directory.path())，放哪一层都行。")
            } actions: {
                Button("在访达中打开") { NSWorkspace.shared.open(directory) }
                Button("重新查找") { Task { await store.load() } }
            }

        case .failed(let message):
            ContentUnavailableView("打不开", systemImage: "exclamationmark.triangle",
                                   description: Text(message))

        case .ready:
            entryPane
        }
    }

    private var entryPane: some View {
        ZStack {
            Color.page.ignoresSafeArea()
            // WebView 词典一就绪就建、常驻不重挂（iOS 同一策略）：先装一个空文档，
            // 把 WebContent 进程和样式表都热好，第一个词免掉冷启动白屏。
            MacEntryWebView(html: document ?? DictionaryStore.emptyDocument,
                            onPlaySound: { store.play(sound: $0) },
                            onToggleFavorite: {
                                guard let word = openedWord else { return false }
                                return history.toggleFavorite(word, preview: store.preview(for: word))
                            })
                .opacity(document == nil ? 0 : 1)
            if document == nil { welcome }
        }
    }

    /// 欢迎页（2026-08-30 用户拍板：不再摆统计仪表）。词头数和冷启动耗时
    /// 原本是 ADR 0008 检验索引缓存的表面——那份职责不丢：同样的数字启动时
    /// 一直打在 stdout 的 [startup] 行，iOS 的开屏页也还在显示。
    /// 「没有词典」的分支在 detail 的 .missing 里，本来就是「请添加词典」。
    private var welcome: some View {
        ContentUnavailableView {
            // 词典名收进悬停提示（用户拍板）：常态只有图标，鼠标停上去才显示
            // 是哪部词典、什么版本。
            Image(systemName: "character.book.closed")
                .help(store.title)
                .accessibilityLabel(store.title)
        } description: {
            VStack(spacing: 6) {
                Text("⌘F 查询单词")
                Text("⌥D 划词翻译")
                Text("⌫ 删除记录")
            }
        }
    }

    // MARK: 动作

    /// ↑↓ 在当前列表里挪选中。没有选中时，↓ 从头开始、↑ 从尾开始。
    /// 返回是否动了——没动的键（空列表）要放行给系统。
    private func move(_ delta: Int) -> Bool {
        let keys = listItems.map(\.word)
        guard !keys.isEmpty else { return false }
        let next: Int
        if let current = selection.flatMap({ keys.firstIndex(of: $0) }) {
            next = min(max(current + delta, 0), keys.count - 1)
        } else {
            next = delta > 0 ? 0 : keys.count - 1
        }
        selection = keys[next]
        return true
    }

    /// 退格删除选中的历史/收藏记录，返回是否真删了（没删的事件要放行给
    /// 文本编辑）。只在搜索框空着时动手——那时列表显示的才是可删的记录，
    /// 候选是词典键无从删起。选中落到下一行（连按可连删），下一行经
    /// onChange 自动打开——「选中即打开」的既有约定，删除不例外。
    private func deleteSelectedRecord() -> Bool {
        guard query.isEmpty, let word = selection,
              let index = listItems.firstIndex(where: { $0.word == word })
        else { return false }
        // 下一行的词条**先**开出来再放动画：变换要 70–100 ms 且在主线程
        //（DictionaryStore.bodyCache 的注释），跟着 selection 的 onChange
        // 落在动画中段就是肉眼可见的掉帧（用户报的）。先开一遍热进缓存，
        // onChange 那一遍就只剩包壳的钱。
        var remaining = listItems.map(\.word)
        remaining.remove(at: index)
        let next = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        if let next { open(next, record: false) }
        withAnimation(.snappy) {
            history.remove(word)
        }
        selection = next
        return true
    }

    /// 回车：整词命中就直接开，没打完就开第一条候选——回车永远有响应。
    private func submit() {
        if open(query, record: true) { return }
        guard let first = suggestions.first?.key else { return }
        if selection == first {
            open(first, record: true)
        } else {
            selection = first    // 触发 onChange → open
        }
    }

    /// 查询词开成词条。**不清 query 和 suggestions**——候选栏留在原地，
    /// 换个词只是再点一行（iOS 的第 5 点在双栏下天然成立）。
    @discardableResult
    private func open(_ word: String, record: Bool) -> Bool {
        // 「文本 → 词」的策略（规范词头等）在 DictionaryStore.resolve(typed:)，
        // 这里只要文档；记不记历史是界面的事，留在下面。
        guard let canonical = store.resolve(typed: word),
              let rendered = store.document(for: canonical,
                                            favorited: history.isFavorite(canonical))
        else { return false }
        document = rendered
        openedWord = canonical
        if record { history.recordOpen(canonical, preview: store.preview(for: canonical)) }
        return true
    }
}
