import Combine
import DictCore
import SwiftUI

/// 主界面。三层一栈：
///
///     首页（历史 + 收藏） ← 搜索结果 ← 词条层（WebView）
///
/// 词条层**常驻**在视图树里，没开词条时整层平移到屏幕右侧外——不是 NavigationStack
/// 的真推栈。原因是那口老锅：WKWebView 重建一次空白 570 ms、首帧 env(safe-area) 为 0
/// （见 EntryWebViewController），真推栈意味着每次 push 重挂 WebView，全部重踩一遍。
/// 平移方案里 WebView 从生到死只挂一次，推入/滑出只是改 offset。
///
/// 右滑返回回到**来的那一页**：结果层在词条层底下原样待着（键盘在滑出动画结束后
/// 由 FocusState 恢复），没在搜索就露出首页。
///
/// ADR 0004 的「一本词典上浮着两片玻璃」不变：底部搜索胶囊、顶部 1pt 注册元素
/// 都套在三层**外面**，每层里的滚动视图（首页列表 / 结果列表 / WebView）都从
/// 玻璃底下穿过去。
struct RootView: View {
    @State private var store = DictionaryStore()
    @State private var history = HistoryStore()
    @State private var query = ""

    /// 候选和正文都**缓存在状态里**，不做成计算属性。
    ///
    /// 计算属性版本每次 body 求值都要重跑一遍搜索、重新渲染一遍 HTML——
    /// 而 body 里访问了它几十次。结果是界面忙到吃不下点击：候选行点了没反应，
    /// 键盘回车却好使。
    @State private var suggestions: [DictionaryStore.Suggestion] = []
    @State private var document: String?

    /// 当前打开的词。nil = 词条层收在屏幕右侧外。
    @State private var openedWord: String?
    /// 返回手势把词条层拖出去了多远。0 = 全屏在位。
    @State private var pullback: CGFloat = 0

    @State private var showFavoritesOnly = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = entryProgress(width: width)
            ZStack {
                // 来处（首页或搜索结果）：词条层推入时向左让 30%，系统导航转场
                // 的视差。压暗只留一点点——实测原生浅色**没有**整体压暗（转场中
                // 底层远处 240 = 上层 240），层次全靠视差和边缘那条淡渐变；
                // 我们两层同色，留 5% 帮一把，再多就比原生沉。
                underLayers
                    .offset(x: -width * 0.3 * progress)
                    .overlay {
                        Color.black.opacity(0.05 * progress)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                if case .ready = store.phase {
                    entryLayer(width: width)
                        .offset(x: openedWord != nil ? pullback : width + 24)
                }
            }
        }
        .background { Color.page.ignoresSafeArea() }
        // 顶部软边缘：**系统原生的滚动边缘效果**，和底部搜索条底下那个是同一个
        // （UIKit 的 ScrollEdgeEffectView，lldb 实测两边参数逐项一致：提亮 0.85、
        // 零模糊，深色自动换成压暗）。它只在滚动视图的这条边上**注册了边缘元素**
        // 时才画——底部是搜索条那片玻璃 bar 注册的，顶部靠这个 1pt · 1% 透明度的
        // 哑元素。四个条件缺一不可，都是实测出来的：
        //   Color.clear             → 不注册（没有渲染内容）
        //   frame(height: 0 / 0.1)  → 不注册（高度取整为零）
        //   .opacity(0)             → 不注册（完全透明视为不存在）
        //   Color.page 不透明        → 注册，但那 1pt 是实色，会把正文切一道缝
        // 代价：env(safe-area-inset-top) 多 1pt，正文整体下移 1pt，无感。
        .safeAreaBar(edge: .top) {
            Color.page.opacity(0.01).frame(height: 1)
        }
        .safeAreaBar(edge: .bottom) { searchBar }
        // tint 要在 safeAreaBar **之后**：bar 的内容不在被它修饰的那棵子树里，
        // 写在前面搜索框的光标和清除键还是系统蓝，和正文的强调色对不上。
        .tint(.accent)
        .task { await store.load() }
        // 内存紧张时把解压区块 / 渲染 / 预览这些能重建的缓存全放掉，
        // 免得系统直接把 App 杀了（那才是最贵的"缓存失效"）。
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.didReceiveMemoryWarning()
        }
        .onChange(of: query) { _, new in
            suggestions = store.suggestions(for: new)
            // 在词条页上打字 = 开一轮新搜索：词条层滑走，让出结果页——无果时
            // 也让，底下现在有「没有找到单词」，不让的话反馈被词条盖着。
            // 按新 query 判断而不是候选：清空（✕ / 全删）不算开新搜索，词条留着。
            if openedWord != nil, !new.trimmingCharacters(in: .whitespaces).isEmpty {
                withAnimation(.entrySlide) { openedWord = nil }
                pullback = 0
            }
        }
    }

    /// 词条层盖住来处的程度：0 = 没开，1 = 全屏在位，手势拖动中在两者之间。
    private func entryProgress(width: CGFloat) -> CGFloat {
        guard openedWord != nil, width > 0 else { return 0 }
        return max(0, 1 - pullback / width)
    }

    // MARK: 首页 + 结果（词条层底下的「来处」）

    @ViewBuilder
    private var underLayers: some View {
        ZStack {
            homeLayer
            if !suggestions.isEmpty {
                resultsLayer
            } else if case .ready = store.phase,
                      !query.trimmingCharacters(in: .whitespaces).isEmpty {
                // 搜索无果的反馈（和 Mac 边栏同一句、同样居中）。以前这个状态
                // 什么都不显示，露出的还是历史列表——查不到和没查过长得一样。
                Text("没有找到单词")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { Color.page.ignoresSafeArea() }
            }
        }
    }

    @ViewBuilder
    private var homeLayer: some View {
        switch store.phase {
        case .loading:
            ProgressView("正在建索引…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .missing:
            ContentUnavailableView {
                Label("还没有词典", systemImage: "book.closed")
            } description: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("把 .mdx 拖进这个 App 的文件夹，放哪一层都行：")
                    Label("「文件」App → 我的 iPhone → Aphros", systemImage: "folder")
                    Label("Finder → 设备 → 文件 → Aphros", systemImage: "laptopcomputer")
                }
                .font(.footnote)
                .frame(maxWidth: 300, alignment: .leading)
            } actions: {
                Button("重新查找") { Task { await store.load() } }
                    .buttonStyle(.glass)
            }

        case .failed(let message):
            ContentUnavailableView("打不开", systemImage: "exclamationmark.triangle",
                                   description: Text(message))

        case .ready:
            homeList
        }
    }

    /// 首页：查过的词，最近在前。一次都没查过时还是开屏统计页。
    @ViewBuilder
    private var homeList: some View {
        let items = showFavoritesOnly ? history.favorites : history.entries
        Group {
            if history.entries.isEmpty {
                welcome
            } else if items.isEmpty {
                ContentUnavailableView {
                    Label("还没有收藏", systemImage: "star")
                } description: {
                    Text("词条页词头右边的星，点一下就收进这里。")
                }
            } else {
                // List 不是 ScrollView + LazyVStack（结果页仍是后者）：左滑删除
                // 只有 List 的 swipeActions 给，自己拿 DragGesture 拼是重造一个
                // 手感更差的。行样式靠三件套抹平成和结果页一样：insets 归零、
                // 行底透明、分隔线用 alignmentGuide 推到 20（原 Divider 的缩进）。
                List {
                    ForEach(items) { entry in
                        Button { open(entry.word) } label: {
                            row(word: entry.word, preview: entry.preview)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 20 }
                        // 原设计分隔线只在行间：末行下面那条藏掉。
                        .listRowSeparator(entry.id == items.last?.id ? .hidden : .automatic,
                                          edges: .bottom)
                        .swipeActions(edge: .trailing) {
                            // 收藏列表里删的也是整条记录（连收藏一起），
                            // 和 Mac ⌫ 的语义一致。纯图标不带文字（用户拍板）：
                            // label 只给 Image，浮动按钮就收成圆形。
                            Button(role: .destructive) {
                                withAnimation { history.remove(entry.word) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            // destructive 的红会被全局 .tint(.accent) 盖成蓝，
                            // 实测截图确认过；删除必须是红的。
                            .tint(.red)
                            .accessibilityLabel("删除")
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 4, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 搜索胶囊右边那颗小玻璃：全部 ↔ 只看收藏。只在首页出现（用户定的位置：
    /// 和搜索栏一行；原先悬浮在右上角，和列表第一行行尾的星既重叠又不对齐）。
    private var filterButton: some View {
        Button {
            withAnimation(.snappy) { showFavoritesOnly.toggle() }
        } label: {
            Image(systemName: showFavoritesOnly ? "star.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(showFavoritesOnly ? Color.fav : Color.primary)
                // .glass 样式会在 label 外自己再垫一圈（实测每边 ~7.5pt），
                // 30 出来正好 ≈ 45，和搜索胶囊（44）一般高。之前写 46 出来 61，
                // 圆钮比胶囊高出一截。
                .frame(width: 30, height: 30)
        }
        // 玻璃必须走系统的 .glass 按钮样式。自己拿 glassEffect 拼（包在 Button
        // 外、塞进 label、当 background 都试过）：玻璃图层会把点击吞掉，
        // 按钮怎么点都没反应——对照实验换成纯色背景立刻就好。
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(showFavoritesOnly ? "显示全部" : "只看收藏")
    }

    /// 过滤钮只在「正看着历史列表」时有意义：进了词条、正在搜索、一条历史
    /// 都没有的时候都收起来，把整行还给搜索胶囊。
    private var showsFilterButton: Bool {
        guard case .ready = store.phase else { return false }
        return openedWord == nil && suggestions.isEmpty && !history.entries.isEmpty
    }

    /// 开屏页顺带把冷启动耗时摆出来。ADR 0008 把「索引要不要落盘」挂在这个数字上，
    /// 而那个数字只有在真机上才算数。查过一个词之后它就退位给历史列表。
    private var welcome: some View {
        ContentUnavailableView {
            Label(store.title, systemImage: "character.book.closed")
        } description: {
            VStack(spacing: 6) {
                Text("\(store.keyCount.formatted()) 个词头")
                if store.resourceCount > 0 {
                    Text("\(store.resourceCount.formatted()) 个音频 / 图片")
                }
                Text("索引 \(ms(store.indexElapsed))\(store.indexFromCache ? "（缓存）" : "（重建）") · 资源 \(ms(store.resourceElapsed))")
                    .font(.caption2).monospaced().foregroundStyle(.tertiary)
            }
        }
    }

    /// 搜索结果。整屏不透明、盖在首页上面，和首页同一套行样式。
    private var resultsLayer: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button { open(suggestion.key) } label: {
                        // 预览是同步取的：单条实测 0.12–0.42 ms 且有缓存，
                        // LazyVStack 一屏只建十几行。异步取会让行高跳一下。
                        row(word: suggestion.key,
                            preview: store.preview(for: suggestion.key))
                    }
                    .buttonStyle(.plain)
                    if suggestion.id != suggestions.last?.id {
                        Divider().padding(.leading, 20)
                    }
                }
            }
            .padding(.top, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { Color.page.ignoresSafeArea() }
    }

    /// 首页和结果页共用的行：词 + 一行中文预览。
    ///
    /// 收藏的行**不带星**：试过行尾放黄星，和底部过滤钮对齐要把左右 padding
    /// 撑到 34，列表整个悬空、间距发怪（用户否掉的）。收藏状态首页不标注，
    /// 想看哪些收藏了点过滤钮。
    private func row(word: String, preview: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // medium 不是 regular：词是行的主体，预览小字是从属——字重和字号
            // 一起分层，扫列表时词头跳出来（用户要的「稍微加粗」）。
            Text(word)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
            if let preview {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        // 少了这行，可点的只有**文字本身**，词右边的空白点不动。
        // .plain 的命中区按渲染出来的形状算，不按 frame。
        .contentShape(.rect)
    }

    // MARK: 词条层

    /// WebView **词典一就绪就建**，不等第一个词：先加载一个空文档，把 WebContent
    /// 进程、样式表、安全区都准备好。等到第一个词再建的话，实测空白 570 ms，而且
    /// 第一帧按 env(safe-area-inset-top)=0 排（视图还没进窗口），词头压在状态栏上。
    /// 空文档也必须是**完整文档**（带 viewport-fit=cover 的 head），不能是 ""，
    /// 否则换真词条时 viewport 变了会重排一帧。
    private func entryLayer(width: CGFloat) -> some View {
        EntryWebView(html: document ?? DictionaryStore.emptyDocument,
                     onPlaySound: { store.play(sound: $0) },
                     onToggleFavorite: {
                         guard let word = openedWord else { return false }
                         return history.toggleFavorite(word, preview: store.preview(for: word))
                     },
                     onEdgePan: { handleEdgePan($0, width: width) })
            // 四边全越界，上下两片玻璃底下才都有东西透出来。让位靠 entry.css 的
            // padding，**不缩 WebView 的 frame**（ADR 0004）。
            .ignoresSafeArea()
            // WebView 是透明的（正文底色由 CSS 铺）——平移进来时下面是首页，
            // 这层自己得不透明，不然两页文字叠在一起。
            .background { Color.page.ignoresSafeArea() }
            // 转场阴影按原生量的：录系统「设置」的返回手势逐像素测，上层页左缘
            // 是**硬边**，阴影是打在底层页上的一条 20pt 渐变、峰值只有 ~2% 黑
            // （240 → 236，深色下干脆不可见）。这里取 5%——我们两层都是素面
            // 没有卡片对比，纯 2% 分不出层。之前的 .shadow(0.18, radius 16)
            // 比原生重了近一个数量级，四边都晕，看着像海报投影。
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0)],
                               startPoint: .trailing, endPoint: .leading)
                    .frame(width: 20)
                    .offset(x: -20)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
    }

    /// 右滑返回。阈值照系统的手感：拖过 1/3 或者甩得够快就走，否则弹回。
    private func handleEdgePan(_ gesture: UIPanGestureRecognizer, width: CGFloat) {
        guard openedWord != nil, width > 0 else { return }
        let translation = gesture.translation(in: gesture.view).x
        switch gesture.state {
        case .changed:
            pullback = max(0, translation)
        case .ended:
            let velocity = gesture.velocity(in: gesture.view).x
            if translation > width / 3 || velocity > 800 {
                closeEntry(width: width)
            } else {
                withAnimation(.entrySlide) { pullback = 0 }
            }
        case .cancelled, .failed:
            withAnimation(.entrySlide) { pullback = 0 }
        default:
            break
        }
    }

    /// 词条层滑出去。动画收尾后才真正置空状态——期间 offset 的两个分支值相同，
    /// 切换不跳。回到结果页时把键盘还给搜索框（用户定的第 5 点）。
    private func closeEntry(width: CGFloat) {
        withAnimation(.entrySlide) {
            pullback = width + 24
        } completion: {
            openedWord = nil
            pullback = 0
            if !suggestions.isEmpty { focusSearchField() }
        }
    }

    // MARK: 底部玻璃

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                // 占位词和 Mac 一致（ADR 0012 当时定的「查询单词」，iOS 跟上）。
                TextField("查询单词", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { open(query) }
                // ✕ 用透明度藏，**不用 if 从视图树上摘**——摘/挂会重排胶囊内部，
                // TextField 的第一响应者跟着被剥夺，键盘毫无征兆地收掉
                // （日志实锤：点 ✕ 清空的瞬间 keyboardDidHide）。占位常驻，
                // 布局一个字节不动，焦点就稳了。
                Button {
                    query = ""
                    // 清空 = 要搜下一个词：焦点还给搜索框、键盘直接拉起
                    //（用户拍板），不用再点一下框。
                    focusSearchField()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        // 图标 17pt 太难点（用户报的）。热区撑到 44（HIG 最小
                        // 触控目标），负 padding 把布局占位缩回 22——胶囊高度
                        // 由 TextField 主导，不跟着 44 长个子；命中区按渲染
                        // 帧算，照旧是 44。
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(-11)
                .opacity(query.isEmpty ? 0 : 1)
                .disabled(query.isEmpty)
                .accessibilityLabel("清空")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)

            if showsFilterButton {
                filterButton
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: showsFilterButton)
        .padding(.horizontal, 16)
        // 键盘弹起时 safeAreaBar 会把自己顶到键盘正上方，贴得太死。
        // 原生搜索栏在这里留 8pt，照它来。
        .padding(.bottom, 8)
    }

    private func ms(_ d: Duration) -> String {
        d.formatted(.units(allowed: [.milliseconds]))
    }

    // MARK: 打开词条

    /// 查询词或候选打开成词条。**不清 query 和 suggestions**——右滑回来要原样
    /// 接着上次的搜索（第 5 点）；点 ✕ 才是主动清（第 6 点，清完露出首页）。
    private func open(_ word: String) {
        // 「文本 → 词」的策略在 DictionaryStore.resolve(typed:)（规范词头：
        // Full 和 full 同一条记录——Mac 先改的，iOS 漏了一轮，2026-08-31 收编时补齐）。
        guard let trimmed = store.resolve(typed: word),
              let rendered = store.document(for: trimmed,
                                            favorited: history.isFavorite(trimmed))
        else { return }
        dismissKeyboard()
        document = rendered
        if openedWord == nil {
            pullback = 0
            // 历史上移**等词条层完全盖住列表再做**：点行的瞬间列表重排 + 词条
            // 推入两个动画叠着跑，看着乱（用户报的）。推入动画收尾时列表在
            // 词条层底下，重排既看不见也不进动画事务——右滑回来时已经排好了。
            withAnimation(.entrySlide) {
                openedWord = trimmed
            } completion: {
                history.recordOpen(trimmed, preview: store.preview(for: trimmed))
            }
        } else {
            // 词条已开着还再开（比如词条页上直接按回车重查）：原地换文档，
            // 列表本来就被盖着，立刻记。内链已去掉（2026-08-30），
            // 这里不再是跳词入口。
            openedWord = trimmed
            history.recordOpen(trimmed, preview: store.preview(for: trimmed))
        }
    }
}


extension Animation {
    /// 词条层推入 / 滑出。参数对着系统导航转场的手感调的。
    static let entrySlide = Animation.spring(response: 0.4, dampingFraction: 0.92)
}


/// 键盘的收与放**全走 UIKit，不用 FocusState**。
///
/// 埋探针实测：`safeAreaBar` 里这个 TextField 的 `@FocusState` 绑定是半残的
/// ——读数**恒为 false**、`onChange` 从不触发；写 true 能拉起键盘、写 false
/// 收不掉。半残的最大危害不是哪条路径失灵，而是 SwiftUI 一直以为「搜索框
/// 没聚焦」，任何一次视图更新都可能把真实焦点「纠正」掉——哪次更新触发
/// 不确定，表现就是「时而点了搜索框键盘不弹 / 弹了又收」（用户报的）。
/// 绑定整个拆除后，点击聚焦是纯原生行为，SwiftUI 无从插手。
@MainActor private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

/// 程序化聚焦（右滑回到结果页时还键盘）：直接找到 SwiftUI TextField 底下的
/// UITextField 让它成为第一响应者。全 App 只有一个文本框，不会找错。
@MainActor private func focusSearchField() {
    guard let window = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
        .first else { return }
    firstTextField(in: window)?.becomeFirstResponder()
}

private func firstTextField(in view: UIView) -> UITextField? {
    for subview in view.subviews {
        if let field = subview as? UITextField { return field }
        if let found = firstTextField(in: subview) { return found }
    }
    return nil
}

// Color.page / .accent / .fav 在 Shared/Colors.swift——双端共用，和 entry.css 逐位对齐。
