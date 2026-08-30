import Foundation

/// L3 渲染层：把词典给的原始 HTML 变成能喂进 WebView 的完整文档。
///
/// **绝大部分排版靠 CSS 完成**（`entry.css` + 每部词典一份映射表 + `hidden.css`），
/// 这里只做 CSS 做不到的三件事：剥掉词典自带的脚本和内联样式、去掉词头里的音节点、
/// 把动词形式折叠块拍平成一行。
///
/// 每个变换都是**锚定的**：找不到锚点就原样放过，不做通用的 HTML 改写。
/// 46 万条词条里总有奇形结构，宁可少一行动词形式，也不要把版式弄坏。
public enum EntryRenderer {

    public struct Options: Sendable {
        /// 隐藏元素编号（对应 ADR 0006 的总表），会变成根元素上的 `h4 h5 h12 …` 类。
        public var hidden: Set<Int>
        /// 义项号按显示顺序重编。21 义群标题隐藏后，run 的原始号会从 1 跳到 8。
        public var renumberSenses: Bool
        /// 去掉词头里的音节分隔点（`a·ban·don` → `abandon`）。CSS 关不掉，它是字面文本。
        public var stripSyllableDots: Bool
        /// 把 `unbox="verbforms"` 折叠块拍平成音标下方一行（第 8 版的形态）。
        public var flattenVerbForms: Bool
        /// 中文里的全角括号、逗号、分号换成半角，并按需补空格。
        public var halfWidthPunctuation: Bool
        /// 词头和音标上提到最前面，每个词性变成词头下面的一节。
        public var sectionsByPartOfSpeech: Bool
        /// 每节默认展开几个义项，其余收进 `<details>`。nil = 全展开。
        public var senseLimit: Int?
        /// 每个义项只留第一个例句。
        public var firstExampleOnly: Bool
        /// ADR 0006 定稿的取舍。
        /// ADR 0006 定稿的取舍。**29 同形异义分栏不在隐藏之列**——那条分隔线
        /// 是"看得出换词性了"的唯一线索。
        public static let standard = Options(
            hidden: [4, 5, 7, 12, 14, 15, 19, 20, 21, 22, 23, 24, 25, 26, 27, 30, 43],
            renumberSenses: true, stripSyllableDots: true, flattenVerbForms: true,
            halfWidthPunctuation: true, sectionsByPartOfSpeech: true,
            senseLimit: 2, firstExampleOnly: true)

        /// 什么都不动，用来对比原貌。
        public static let raw = Options(hidden: [], renumberSenses: false,
                                        stripSyllableDots: false, flattenVerbForms: false,
                                        halfWidthPunctuation: false, sectionsByPartOfSpeech: false,
                                        senseLimit: nil, firstExampleOnly: false)

        public init(hidden: Set<Int>, renumberSenses: Bool, stripSyllableDots: Bool,
                    flattenVerbForms: Bool, halfWidthPunctuation: Bool = false,
                    sectionsByPartOfSpeech: Bool = false, senseLimit: Int? = nil,
                    firstExampleOnly: Bool = false) {
            self.hidden = hidden
            self.renumberSenses = renumberSenses
            self.stripSyllableDots = stripSyllableDots
            self.flattenVerbForms = flattenVerbForms
            self.halfWidthPunctuation = halfWidthPunctuation
            self.sectionsByPartOfSpeech = sectionsByPartOfSpeech
            self.senseLimit = senseLimit
            self.firstExampleOnly = firstExampleOnly
        }
    }

    /// 词典的标记方言。同一套视觉，每部词典一份映射表。
    /// 只剩第 10 版一个 case——第 8 版备用已取消（ADR 0007，2026-08-25），
    /// 枚举留着是给「换词典」保个形状，不是留后门。
    public enum Dialect: String, Sendable {
        case oaldpe = "oa10"           // 牛津高阶第 10 版（主用）

        var mapStylesheet: String {
            switch self {
            case .oaldpe: "oaldpe-map.css"
            }
        }
    }

    // MARK: 对外

    /// 完整的 HTML 文档。`stylesheetPrefix` 是样式表的 URL 前缀，交给 WebView 的
    /// scheme handler 解析。
    public static func document(for record: String,
                                dialect: Dialect = .oaldpe,
                                options: Options = .standard,
                                stylesheetPrefix: String = "dict://asset/",
                                extraRootClasses: [String] = []) -> String {
        document(preTransformedBody: transform(record, options: options),
                 dialect: dialect, options: options, stylesheetPrefix: stylesheetPrefix,
                 extraRootClasses: extraRootClasses)
    }

    /// 已经变换过的正文包成文档。同名词头有多条时（「上当」在 OALDPE 里有两条），
    /// 界面层会先各自变换再拼起来，所以要一个不重复变换的入口。
    ///
    /// `extraRootClasses` 挂在根元素上，给**界面状态**用（现在只有收藏态 `faved`）
    /// ——渲染层自己的开关类（h4…、renum）都从 options 推出来，界面层的状态它
    /// 不该知道，从这里塞进来。
    public static func document(preTransformedBody body: String,
                                dialect: Dialect = .oaldpe,
                                options: Options = .standard,
                                stylesheetPrefix: String = "dict://asset/",
                                extraRootClasses: [String] = []) -> String {
        var rootClasses = [dialect.rawValue]
        rootClasses += options.hidden.sorted().map { "h\($0)" }
        rootClasses += extraRootClasses
        if options.renumberSenses   { rootClasses.append("renum") }
        if options.firstExampleOnly { rootClasses.append("ex1") }

        let sheets = ["entry.css", dialect.mapStylesheet, "hidden.css"]
            .map { #"<link rel="stylesheet" href="\#(stylesheetPrefix)\#($0)">"# }
            .joined()

        return """
        <!doctype html><html class="\(rootClasses.joined(separator: " "))"><head>\
        <meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\
        \(sheets)</head><body>\(body)</body></html>
        """
    }

    /// 只做正文变换，不包文档。测试和诊断用。
    public static func transform(_ record: String, options: Options = .standard) -> String {
        var html = bodyContent(of: record)
        html = stripHazards(html)
        if options.stripSyllableDots    { html = removeSyllableDots(html) }
        html = wrapPhoneticsInButton(html)
        html = stackPhrasalVariants(html)
        html = markDuplicatePhrasalVariants(html)
        if options.flattenVerbForms     { html = flattenVerbForms(html) }
        if options.halfWidthPunctuation { html = halfWidthPunctuation(html) }
        // 上提词头要在拍平动词形式**之后**——那张折叠表格里每个形式各有一份音标，
        // 不先拍平的话「第一处音标」会取到表格里的。
        if options.sectionsByPartOfSpeech { html = hoistHeadword(html) }
        html = injectFavoriteButton(html)
        if let keep = options.senseLimit  { html = collapseExtraSenses(html, keep: keep) }
        return html
    }

    // MARK: 收藏按钮

    /// 词头行末尾那颗星。点击走 `fav://toggle` 导航，壳层拦下来改收藏状态，
    /// 再把根元素的 `faved` 类切一下——星是空心还是实心全由 CSS 看这个类。
    /// 和 entry:// / sound:// 同一套机制，正文里照旧零脚本。
    static let favoriteAnchor = #"<a class="fav" href="fav://toggle" aria-label="收藏">"#
        + #"<svg viewBox="0 0 24 24"><path d="M12 2.5 14.65 8.36 21.03 9.06 16.28 13.39 "#
        + #"17.58 19.69 12 16.5 6.42 19.69 7.72 13.39 2.97 9.06 9.35 8.36Z"/></svg></a>"#

    /// 没走上提的词条也要有星：中文词头（`.headw`）和独立习语（`idm-g` 的
    /// `.webtop .idm`，没有 h1.headword）。已经有星（hoistHeadword 放的）就不动。
    /// 找不到任何词头锚点原样放过——元数据页没有星是对的。
    static func injectFavoriteButton(_ html: String) -> String {
        guard !html.contains(#"class="fav""#) else { return html }

        if let open = html.range(of: #"<div class="headw">"#),
           let close = html.range(of: "</div>", range: open.upperBound..<html.endIndex) {
            return String(html[..<close.lowerBound]) + favoriteAnchor + String(html[close.lowerBound...])
        }
        if let webtop = html.range(of: #"class="webtop""#),
           let idm = html.range(of: #"<span class="idm""#, range: webtop.upperBound..<html.endIndex),
           let end = endOfElement(in: html, tag: "span", openingAt: idm.lowerBound) {
            return String(html[..<end]) + favoriteAnchor + String(html[end...])
        }
        return html
    }

    // MARK: 切出正文

    /// 词典给的记录是 `<link><script>…<body><body-content …>正文</body-content></body>`。
    /// 只取 `<body-content>` 那一段——脚本和样式表引用连同外壳一起丢掉。
    static func bodyContent(of record: String) -> String {
        guard let open = record.range(of: "<body-content"),
              let openEnd = record[open.lowerBound...].firstIndex(of: ">"),
              let close = record.range(of: "</body-content>", options: .backwards)
        else { return record }
        let inner = record[record.index(after: openEnd)..<close.lowerBound]
        // body-content 上的 class（`oaldpe`）要留着，映射表里有规则挂在上面。
        let attributes = record[open.upperBound..<openEnd]
        return "<body-content\(attributes)>\(inner)</body-content>"
    }

    // MARK: 剥危险物

    /// 剥 `<script>`、`<link>`、内联 `style` 和 `on*` 事件属性。
    ///
    /// 主要防线其实不在这里，而在 WebView 的 scheme handler：对 `.js` 请求直接返回
    /// 404，OALDPE 那 1,703 行脚本（`touchToTranslate` 点例句切中文、`showSyllable`
    /// 点单词切音节）就不会注册任何事件，也就不会跟 iOS 长按选词抢事件。
    /// 这里再剥一遍是双保险，顺手把内联样式也去掉——实测全库只有三种取值
    /// （`cursor: pointer` / `margin-right: .3rem` / `margin-top: .3rem`），
    /// 全是词典自己那套版式的残留，**没有一处是 `display:none`**，剥掉不会藏住内容。
    ///
    /// 四步等价的正则（原实现，ScanParityTests 拿它们当参考做全库差分）：
    /// `<script\b[^>]*>[\s\S]*?</script>` / `<link\b[^>]*>` /
    /// `\s+style="[^"]*"` / `\s+on[a-z]+="[^"]*"`。
    /// 重写成字节扫描是因为 Swift Regex 按字素簇走，光这一个函数在 light
    /// （208 KB）上要 19 ms——transform 全程的四分之一。
    static func stripHazards(_ html: String) -> String {
        var bytes = Array(html.utf8)
        bytes = removeScriptBlocks(bytes)
        bytes = removeLinkTags(bytes)
        bytes = removeStyleAttributes(bytes)
        bytes = removeEventAttributes(bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `<script\b[^>]*>[\s\S]*?</script>`：开标签到第一个 `>`，再懒惰到第一个闭标签。
    private static func removeScriptBlocks(_ bytes: [UInt8]) -> [UInt8] {
        let open = Array("<script".utf8), close = Array("</script>".utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let s = findBytes(open, in: bytes, from: search) {
            let after = s + open.count
            // \b：script 后面紧跟单词字符（<scripts…）就不算
            if after < bytes.count, isWordByte(bytes[after]) { search = after; continue }
            guard let gt = findBytes([UInt8(ascii: ">")], in: bytes, from: after),
                  let end = findBytes(close, in: bytes, from: gt + 1)
            else { search = after; continue }
            out += bytes[copied..<s]
            copied = end + close.count
            search = copied
        }
        out += bytes[copied...]
        return out
    }

    /// `<link\b[^>]*>`：开标签整个去掉。
    private static func removeLinkTags(_ bytes: [UInt8]) -> [UInt8] {
        let open = Array("<link".utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let s = findBytes(open, in: bytes, from: search) {
            let after = s + open.count
            if after < bytes.count, isWordByte(bytes[after]) { search = after; continue }
            guard let gt = findBytes([UInt8(ascii: ">")], in: bytes, from: after) else { break }
            out += bytes[copied..<s]
            copied = gt + 1
            search = copied
        }
        out += bytes[copied...]
        return out
    }

    /// `\s+style="[^"]*"`：属性连同它前面的空白一起去掉。
    private static func removeStyleAttributes(_ bytes: [UInt8]) -> [UInt8] {
        let marker = Array(#"style=""#.utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let p = findBytes(marker, in: bytes, from: search) {
            var start = p
            while start > copied, isASCIIWhitespace(bytes[start - 1]) { start -= 1 }
            guard start < p,   // \s+ 至少一个
                  let q = findBytes([UInt8(ascii: "\"")], in: bytes, from: p + marker.count)
            else { search = p + 1; continue }
            out += bytes[copied..<start]
            copied = q + 1
            search = copied
        }
        out += bytes[copied...]
        return out
    }

    /// `\s+on[a-z]+="[^"]*"`：锚在 `="` 上，向前吃小写字母、验证打头是 on、再要一个空白。
    private static func removeEventAttributes(_ bytes: [UInt8]) -> [UInt8] {
        let marker: [UInt8] = [UInt8(ascii: "="), UInt8(ascii: "\"")]
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let p = findBytes(marker, in: bytes, from: search) {
            var k = p
            while k > copied, bytes[k - 1] >= 0x61, bytes[k - 1] <= 0x7A { k -= 1 }
            guard p - k >= 3,                                    // on + [a-z]+ ≥ 1
                  bytes[k] == UInt8(ascii: "o"), bytes[k + 1] == UInt8(ascii: "n"),
                  k > copied, isASCIIWhitespace(bytes[k - 1]),
                  let q = findBytes([UInt8(ascii: "\"")], in: bytes, from: p + marker.count)
            else { search = p + 1; continue }
            var start = k
            while start > copied, isASCIIWhitespace(bytes[start - 1]) { start -= 1 }
            out += bytes[copied..<start]
            copied = q + 1
            search = copied
        }
        out += bytes[copied...]
        return out
    }

    // MARK: 02 音节点

    /// `<h1 class="headword" … syllable="a·ban·don">a·ban·don</h1>` → 正文里的间隔号去掉。
    ///
    /// 只动 `h1.headword` 的文本节点，不动 `syllable` 属性——那是标签内部，
    /// 一起改会让「哪天想把音节点放回来」失去依据。间隔号是 U+00B7。
    ///
    /// h1 里可能嵌着子标签：同形号 `<span class="hm">1</span>`（buffet¹²）、
    /// 人名前缀 `<span class="st">A E</span>`（A E Hous·man）。曾经按 `[^<]*` 只认
    /// 纯文本 h1，这批词条（抽样 3.1%）一个点都没去掉——实拍词头是「buf·fet1」。
    /// 现在吃整段内容、扫描时跳过标签内部，子标签和它们的属性一个字节不动。
    ///
    /// 等价正则（参考实现）：`(<h1\b[^>]*class="[^"]*headword[^"]*"[^>]*>)([\s\S]*?)(</h1>)`，
    /// 组 2 里标签外的 U+00B7（UTF-8 是 C2 B7，不会出现在别的序列里）滤掉。
    static func removeSyllableDots(_ html: String) -> String {
        let bytes = Array(html.utf8)
        let h1 = Array("<h1".utf8), closeH1 = Array("</h1>".utf8)
        let classAttr = Array(#"class=""#.utf8), headword = Array("headword".utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let s = findBytes(h1, in: bytes, from: search) {
            let after = s + h1.count
            if after < bytes.count, isWordByte(bytes[after]) { search = after; continue }
            guard let gt = findBytes([UInt8(ascii: ">")], in: bytes, from: after) else { break }
            // class="…headword…" 要整个落在开标签里
            guard let ca = findBytes(classAttr, in: bytes, from: after), ca < gt,
                  let vq = findBytes([UInt8(ascii: "\"")], in: bytes, from: ca + classAttr.count),
                  vq < gt,
                  let hw = findBytes(headword, in: bytes, from: ca + classAttr.count),
                  hw + headword.count <= vq,
                  let end = findBytes(closeH1, in: bytes, from: gt + 1)
            else { search = after; continue }
            out += bytes[copied..<(gt + 1)]
            var i = gt + 1
            var inTag = false
            while i < end {
                let b = bytes[i]
                if b == UInt8(ascii: "<") { inTag = true }
                if b == 0xC2, !inTag, i + 1 < end, bytes[i + 1] == 0xB7 { i += 2; continue }
                out.append(b)
                if b == UInt8(ascii: ">") { inTag = false }
                i += 1
            }
            copied = end
            search = end
        }
        out += bytes[copied...]
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: 33 动词形式拍平

    /// 把 `unbox="verbforms"` 的折叠表格换成音标下面一行 `abandon · abandons · abandoned · abandoning`。
    ///
    /// **按值去重是必需的**：实测 98% 的动词 past 与 pastpart 相同，不去重会连着出现
    /// 两个一样的。不规则动词自然保留全部（go·goes·went·gone·going），
    /// run 的 pastpart 与原形重复，去重后是 run·runs·ran·running。
    ///
    /// 抽不到值就原样返回——`.h30` 本来就会把折叠块藏掉，最坏结果是「少一行动词形式」，
    /// 而不是版式坏掉。
    static func flattenVerbForms(_ html: String) -> String {
        // 锚点是 `unbox="verbforms"` 属性本身，不是整段开标签——属性顺序会变
        // （abandon 是 class 在前，serendipity 是 id 在前），按整段匹配会漏掉一半。
        guard let marker = html.range(of: #"unbox="verbforms""#),
              let unbox = html.range(of: "<span", options: .backwards,
                                     range: html.startIndex..<marker.lowerBound),
              let unboxEnd = endOfElement(in: html, tag: "span", openingAt: unbox.lowerBound)
        else { return html }

        let values = verbForms(in: html[unbox.lowerBound..<unboxEnd])
        guard values.count >= 2 else { return html }

        // 插到外层折叠块**之前**，这样 .h30 藏掉折叠块时这一行还在。
        var insertAt = unbox.lowerBound
        if let collapse = html.range(of: #"<div class="collapse">"#, options: .backwards,
                                     range: html.startIndex..<unbox.lowerBound),
           html.distance(from: collapse.upperBound, to: unbox.lowerBound) < 8 {
            insertAt = collapse.lowerBound
        }

        let flat = #"<div class="vforms">"# + values.joined(separator: "<i>·</i>") + "</div>"
        return String(html[html.startIndex..<insertAt]) + flat
             + String(html[insertAt..<unbox.lowerBound]) + String(html[unboxEnd...])
    }

    /// 表格里每个 `<td class="verb_form">` 的值：`<span class="vf_prefix">前缀</span> 值`。
    /// 取最后一个 `</span>` 到 `</td>` 之间的文本，按出现顺序去重。
    private static func verbForms(in fragment: Substring) -> [String] {
        var values: [String] = []
        var cursor = fragment.startIndex
        while let cell = fragment.range(of: #"<td class="verb_form">"#,
                                        range: cursor..<fragment.endIndex) {
            guard let cellEnd = fragment.range(of: "</td>", range: cell.upperBound..<fragment.endIndex)
            else { break }
            let inner = fragment[cell.upperBound..<cellEnd.lowerBound]
            let text = inner.range(of: "</span>", options: .backwards)
                .map { String(inner[$0.upperBound...]) } ?? String(inner)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.contains("<"), !values.contains(value) { values.append(value) }
            cursor = cellEnd.upperBound
        }
        return values
    }

    /// 每个地区第一个读法之外还剩几个。实测 59,171 条有音标的词条里 95.33% 正好是
    /// 「英 1 + 美 1」，只有 4.66%（2,759 条）有第三个——为这 4.66% 把默认视图撑
    /// 成三行不划算，多出来的收进一个开关里。
    ///
    /// 开关是 `<label>` 包着一个隐藏的 checkbox，不是 `<details>`：`<details>` 要求
    /// 多出来的读法搬进它内部，等于重排词典自己的标记；checkbox 只往后面追加一个
    /// 元素，藏和放全交给 CSS 的 `:has()`。正文里的脚本是全禁的（ADR 0009），
    /// label→checkbox 是浏览器原生行为，不需要 JS。
    ///
    /// 不用 id 关联，靠 `<label>` **包住** input——同名词头有多条时界面层会把几份
    /// 正文拼进同一个文档，id 会撞。
    static func moreReadingsToggle(_ phonetics: String) -> String {
        var extra = 0
        for group in ["phons_br", "phons_n_am"] {
            guard let s = phonetics.range(of: "<div class=\"\(group)\">"),
                  let e = phonetics.range(of: "</div>", range: s.upperBound..<phonetics.endIndex)
            else { continue }
            let n = phonetics[s.upperBound..<e.lowerBound]
                .components(separatedBy: "<a class=\"sound").count - 1
            extra += max(0, n - 1)
        }
        guard extra > 0 else { return "" }
        return #"<label class="morephon" data-n="\#(extra)"><input type="checkbox"></label>"#
    }

    // MARK: 发音按钮

    /// 把音标和它的限定标签挪进喇叭的 `<a>` 里，整段都可点。
    ///
    /// 词典原本是 `<a class="sound"></a><span class="phon">/…/</span>` —— 喇叭是个
    /// 空标签，音标是它的兄弟。这样只有那个小图标可点，而它在屏幕上不到 16pt。
    /// 挪进去之后按钮变成「图标 + BrE + 音标」一整段，触控面积大一个量级。
    ///
    /// 短语动词的变体标题 `turn around | turn somebody/something around` 拆成
    /// 一行一个式子。竖线是纸书省空间的记法：实测抽样 499 行里带 `|` 的只有 8%，
    /// 但整行长度 p90 是 43 字符——正好卡在 402pt 的换行边缘，要断行时断点落在
    /// 式子**中间**；单个式子 p90 只有 38 字符，一行一个就永远不用拗口地断。
    /// 只动 `.pv` span 里的文本（实测全库该 span 内容都是纯文本），别处的 `|` 不碰。
    static func stackPhrasalVariants(_ html: String) -> String {
        guard html.contains(#"class="pv""#) else { return html }
        var out = ""
        var rest = Substring(html)
        while let open = rest.range(of: #"<span class="pv""#) {
            guard let gt = rest[open.upperBound...].firstIndex(of: ">"),
                  let close = rest[gt...].range(of: "</span>") else { break }
            out += rest[rest.startIndex...gt]
            out += rest[rest.index(after: gt)..<close.lowerBound]
                .replacingOccurrences(of: " | ", with: "<br>")
            out += "</span>"
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    /// 式子和词头一模一样的 .pv 打上 `pv-dup`，由 CSS 藏。
    ///
    /// 实测抽样 499 个 pv 块：12% 整行就是词头本身，零新信息，纯重复；
    /// 另有 3% 是多式子里**有一个**等于词头（turn around | turn sb/sth around）——
    /// 那个不是重复，是「可以不及物」这条信息本身，多式子的一律不动。
    /// 打类不删数据，和 noaudio 一个做法。
    static func markDuplicatePhrasalVariants(_ html: String) -> String {
        guard html.contains(#"class="pv""#) else { return html }
        // 词头 = 第一个 h1.headword 的文本（此时词头还没上提，标记原样在正文里）。
        guard let hwOpen = html.range(of: #"class="headword""#),
              let hwGt = html[hwOpen.upperBound...].firstIndex(of: ">"),
              let hwLt = html[hwGt...].range(of: "<") else { return html }
        let headword = html[html.index(after: hwGt)..<hwLt.lowerBound]
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !headword.isEmpty else { return html }

        var out = ""
        var rest = Substring(html)
        while let open = rest.range(of: #"<span class="pv""#) {
            guard let gt = rest[open.upperBound...].firstIndex(of: ">"),
                  let close = rest[gt...].range(of: "</span>") else { break }
            let text = rest[rest.index(after: gt)..<close.lowerBound]
            // stackPhrasalVariants 已经跑过：多式子的含 <br>，不动。
            let isDup = !text.contains("<br>")
                && text.trimmingCharacters(in: .whitespaces).lowercased() == headword
            out += rest[rest.startIndex..<open.lowerBound]
            out += isDup ? #"<span class="pv pv-dup""# : #"<span class="pv""#
            out += rest[open.upperBound..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    /// `<span class="prefix">strong form</span>` 同理：它是**后面那个**读法的限定语
    /// （and / of / was / to 这类虚词有弱读和强读两套），留在外面就是分段控件里一段
    /// 游离的散文，把整行挤变形。挪进去之后它和 BrE/NAmE 一样是段内的小标签。
    ///
    /// 世界英语读音组（`div.phons_we`，全库 141 处）的结构又不一样：喇叭是**空标签**，
    /// 地区名（`span.phon_label`）和音标都在它后面——不挪的话喇叭宽度为零点不到，
    /// 这组发音根本放不出来。挪法同上，顺手把地区名换成中文短标签，和 ::before
    /// 生成的「英 / 美」同一形制；全库只有四个值（下表），不认识的原样保留。
    ///
    /// 挪动只改标签位置，属性一个字节没改。
    static let phonLabelNames: [String: String] = [
        "South African English": "南非",
        "East African English": "东非",
        "West African English": "西非",
        "South-East Asian English": "东南亚",
    ]

    /// 三步等价的正则（参考实现，差分测试用）：
    /// 1. `</a>\s*<span class="phon_label">([^<]*)</span>\s*(<span class="phon">[^<]*</span>)`
    ///    → label（查表换中文短名，查不到就 trim 后原样）+ 音标 span + `</a>`
    /// 2. `</a>(<span class="phon">[^<]*</span>)` → 音标 span + `</a>`（严格相邻，无空白）
    /// 3. `(<span class="prefix">[^<]*</span>)\s*(<a class="sound[^>]*>)` → 对调（中间空白丢掉）
    static func wrapPhoneticsInButton(_ html: String) -> String {
        // 先处理带地区名的（phon_label + phon），再处理裸音标的——
        // 后者的模式匹配不到前者（中间隔着 label），顺序只是为了读起来清楚。
        var bytes = Array(html.utf8)
        bytes = movePhonLabelIntoButton(bytes)
        bytes = movePhonIntoButton(bytes)
        bytes = movePrefixIntoButton(bytes)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func movePhonLabelIntoButton(_ bytes: [UInt8]) -> [UInt8] {
        let labelOpen = Array(#"<span class="phon_label">"#.utf8)
        let phonOpen = Array(#"<span class="phon">"#.utf8)
        let closeSpan = Array("</span>".utf8), closeA = Array("</a>".utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let lp = findBytes(labelOpen, in: bytes, from: search) {
            // 往前：\s*，再往前必须正是 </a>
            var j = lp
            while j > copied, isASCIIWhitespace(bytes[j - 1]) { j -= 1 }
            guard j - copied >= closeA.count, hasBytes(bytes, at: j - closeA.count, closeA),
                  // label 是 [^<]* 到下一个 <，且那里必须正是 </span>
                  let lt1 = findBytes([UInt8(ascii: "<")], in: bytes, from: lp + labelOpen.count),
                  hasBytes(bytes, at: lt1, closeSpan)
            else { search = lp + 1; continue }
            var k = lt1 + closeSpan.count
            while k < bytes.count, isASCIIWhitespace(bytes[k]) { k += 1 }
            guard hasBytes(bytes, at: k, phonOpen),
                  let lt2 = findBytes([UInt8(ascii: "<")], in: bytes, from: k + phonOpen.count),
                  hasBytes(bytes, at: lt2, closeSpan)
            else { search = lp + 1; continue }
            let matchEnd = lt2 + closeSpan.count
            let label = String(decoding: bytes[(lp + labelOpen.count)..<lt1], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            out += bytes[copied..<(j - closeA.count)]
            out += labelOpen
            out += Array((Self.phonLabelNames[label] ?? label).utf8)
            out += closeSpan
            out += bytes[k..<matchEnd]
            out += closeA
            copied = matchEnd
            search = matchEnd
        }
        out += bytes[copied...]
        return out
    }

    private static func movePhonIntoButton(_ bytes: [UInt8]) -> [UInt8] {
        let anchor = Array(#"</a><span class="phon">"#.utf8)
        let closeSpan = Array("</span>".utf8), closeA = Array("</a>".utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let p = findBytes(anchor, in: bytes, from: search) {
            guard let lt = findBytes([UInt8(ascii: "<")], in: bytes, from: p + anchor.count),
                  hasBytes(bytes, at: lt, closeSpan)
            else { search = p + 1; continue }
            let matchEnd = lt + closeSpan.count
            out += bytes[copied..<p]
            out += bytes[(p + closeA.count)..<matchEnd]
            out += closeA
            copied = matchEnd
            search = matchEnd
        }
        out += bytes[copied...]
        return out
    }

    private static func movePrefixIntoButton(_ bytes: [UInt8]) -> [UInt8] {
        let prefixOpen = Array(#"<span class="prefix">"#.utf8)
        let closeSpan = Array("</span>".utf8)
        let soundOpen = Array(#"<a class="sound"#.utf8)
        var out: [UInt8] = []; out.reserveCapacity(bytes.count)
        var copied = 0, search = 0
        while let p = findBytes(prefixOpen, in: bytes, from: search) {
            guard let lt = findBytes([UInt8(ascii: "<")], in: bytes, from: p + prefixOpen.count),
                  hasBytes(bytes, at: lt, closeSpan)
            else { search = p + 1; continue }
            let spanEnd = lt + closeSpan.count
            var k = spanEnd
            while k < bytes.count, isASCIIWhitespace(bytes[k]) { k += 1 }
            guard hasBytes(bytes, at: k, soundOpen),
                  let gt = findBytes([UInt8(ascii: ">")], in: bytes, from: k + soundOpen.count)
            else { search = p + 1; continue }
            out += bytes[copied..<p]
            out += bytes[k..<(gt + 1)]
            out += bytes[p..<spanEnd]
            copied = gt + 1
            search = copied
        }
        out += bytes[copied...]
        return out
    }

    // MARK: 字节扫描基建

    /// Swift Regex 按字素簇走，热 pass 全文扫一遍就是十几毫秒；这些 pass 找的
    /// 全是 ASCII 字面量，退到 UTF-8 字节 + memmem 上是几十倍的差距。
    /// UTF-8 的多字节序列不含 ASCII 字节，按字节找 ASCII 字面量不会误伤。
    private static func findBytes(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard start < haystack.count, haystack.count - start >= needle.count, !needle.isEmpty
        else { return nil }
        return haystack.withUnsafeBufferPointer { h -> Int? in
            needle.withUnsafeBufferPointer { n -> Int? in
                guard let p = memmem(h.baseAddress! + start, h.count - start,
                                     n.baseAddress!, n.count) else { return nil }
                return h.baseAddress!.distance(to: p.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    private static func hasBytes(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        guard index >= 0, index + pattern.count <= bytes.count else { return false }
        for (offset, byte) in pattern.enumerated() where bytes[index + offset] != byte { return false }
        return true
    }

    /// 正则 `\s` 的 ASCII 子集。词典标记里没有 Unicode 空白（全库差分验证过），
    /// 真出现了差分测试会当场红。
    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
    }

    /// 正则 `\b` 用的单词字符（[A-Za-z0-9_]）。
    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || (b >= 0x30 && b <= 0x39) || b == 0x5F
    }

    // MARK: 没有音频的喇叭

    /// 给取不到音频的 `a.sound` 打上 `noaudio`，由 CSS 藏掉。
    ///
    /// 实测 1.57% 的发音引用在 mdd 里没有对应文件（词典自己缺的）。
    /// 不藏的话那些喇叭点了毫无反应，而"点了没反应"比"没有按钮"难受得多。
    public static func markMissingAudio(_ html: String, isAvailable: (String) -> Bool) -> String {
        html.replacing(/<a class="(sound[^"]*)" href="sound:\/\/([^"]+)"/) { match in
            isAvailable(String(match.2))
                ? String(match.0)
                : #"<a class="\#(match.1) noaudio" href="sound://\#(match.2)""#
        }
    }

    // MARK: 中文标点

    /// 全角括号 `（）`、逗号 `，`、分号 `；` 换成半角，并按需补空格。
    ///
    /// 全角标点自带半个字宽的留白，中文释义里到处是它，看起来就是「间距忽大忽小」。
    /// 换成半角之后又贴得太死，补空格的规则两条不同：
    ///
    /// - **括号**只在**另一侧是汉字**时补——`（不顾责任、义务等）离弃` →
    ///   `(不顾责任、义务等) 离弃`，而 `弃船（因船快要沉没）。` → `弃船 (因船快要沉没)。`，
    ///   句号前不补。
    /// - **逗号和分号一律补**，因为英文标点后面就是要有空格；已经有空格时不叠加。
    ///   文本节点末尾的也补：那儿后面跟的是标签，句子在标签边界上继续
    ///   （`英式英语，<span>非正式用语</span>`）。行尾多出来的那个空格浏览器自己收掉。
    ///
    /// 只动**文本节点**，标签内部一个字节不碰——实测 1,075 处全角逗号在属性值里
    /// （`title="…，…"`），改了不影响显示但没必要动。
    ///
    /// **只动释义，例句一个字节不动。** 释义是并列的短语（`离弃，遗弃，抛弃`），
    /// 全角标点的半个字宽在这种地方就是「间距忽大忽小」；例句是散文句子
    /// （`他们不得不舍弃土地，让侵略军占领。`），全角本来就是对的排法。
    /// 跳过的三处见 `isExampleOpen`。
    static func halfWidthPunctuation(_ html: String) -> String {
        // 中文词头的例句列表：整条都是例句（`上当` → 一串含它的英文句子 + 中译），
        // 连词头带走。实测抽样 23,120 条里，它和 deft / 普通词条列表**从不同时出现**，
        // 所以整条判断是安全的。
        if html.contains(#"class="leon-zh-en examples""#) { return html }

        var out = ""
        out.reserveCapacity(html.count)
        var index = html.startIndex
        var ulDepth = 0            // >0：在 <ul class="examples"> 里
        var skipUntil: Substring?  // 在 <xt>/<unxt> 里，等这个闭标签
        while let open = html[index...].firstIndex(of: "<") {
            let text = html[index..<open]
            out += (ulDepth > 0 || skipUntil != nil) ? String(text) : convertPunctuation(text)
            guard let close = html[open...].firstIndex(of: ">") else {
                out += html[open...]; return out
            }
            let tag = html[html.index(after: open)..<close]
            out += html[open...close]
            index = html.index(after: close)

            let name = tagName(tag)
            if let want = skipUntil {
                if tag.hasPrefix("/"), name == want { skipUntil = nil }
            } else if ulDepth > 0 {
                // 例句表里还能再嵌 <ul>，要数层数。实测 <ul> 全库配对无一处不平衡。
                if name == "ul" { ulDepth += tag.hasPrefix("/") ? -1 : 1 }
            } else if !tag.hasPrefix("/"), isExampleOpen(tag, name) {
                if name == "ul" { ulDepth = 1 } else { skipUntil = name }
            }
        }
        let tail = html[index...]
        out += (ulDepth > 0 || skipUntil != nil) ? String(tail) : convertPunctuation(tail)
        return out
    }

    /// 例句区的三个入口：例句表、例句中译、unbox 例句中译。
    /// `undt`（unbox 里的中译）两边都出现，靠它在不在例句表里区分——实测例句区内 328 处、
    /// 区外 1,679 处，一个标签名分不开，只能看祖先。
    private static func isExampleOpen(_ tag: Substring, _ name: Substring) -> Bool {
        if name == "ul" { return tag.contains("examples") }
        return name == "xt" || name == "unxt"
    }

    private static func tagName(_ tag: Substring) -> Substring {
        (tag.hasPrefix("/") ? tag.dropFirst() : tag).prefix { !$0.isWhitespace && $0 != "/" }
    }

    private static func isIdeograph(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3400...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    private static func convertPunctuation(_ text: Substring) -> String {
        guard text.contains("（") || text.contains("）")
                || text.contains("，") || text.contains("；") else { return String(text) }
        var out = ""
        out.reserveCapacity(text.count + 8)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            switch c {
            case "（":
                if let last = out.last, isIdeograph(last) { out.append(" ") }
                out.append("(")
            case "）":
                out.append(")")
            case "，", "；":
                // 空格只在后面，不在前面。词典里有 `粗鲁地 ，下流地` 这种源头就带
                // 前置空格的，实测抽样 36,368 条里 27 处，不吃掉会变成 `粗鲁地 , 下流地`。
                while out.last == " " { out.removeLast() }
                out.append(c == "，" ? "," : ";")
                if next == text.endIndex || text[next] != " " { out.append(" ") }
            default:
                if out.last == ")", isIdeograph(c) { out.append(" ") }
                out.append(c)
            }
            i = next
        }
        return out
    }

    // MARK: 释义预览

    /// 首页和候选列表里词条名后面那行小字。
    ///
    /// 英文词条取**第一条释义的简体中文**：第一个 `<deft>` 里的 `<chn class="simple">`，
    /// 标签剥掉、全角标点按正文同一套规则换半角——预览和点开后第一眼看到的中译
    /// 长得一样。没有中译的义项退回英文释义（`span.def`）。
    ///
    /// 中文词头条目（leon-zh-en 例句表）没有释义，预览换成它指向的英文词，
    /// 按出现顺序去重取前三个（`dupe · victim · crowd`）。
    ///
    /// 都抽不到返回 nil，界面上那行小字就不显示。
    public static func preview(for record: String) -> String? {
        guard !record.hasPrefix("@@@LINK=") else { return nil }
        let html = bodyContent(of: record)
        if html.contains(#"class="leon-zh-en"#) { return englishTargets(html) }

        if let deft = html.range(of: "<deft"),
           let open = html.range(of: #"<chn class="simple">"#,
                                 range: deft.upperBound..<html.endIndex),
           let close = html.range(of: "</chn>", range: open.upperBound..<html.endIndex) {
            let text = plainText(html[open.upperBound..<close.lowerBound])
            if !text.isEmpty { return text }
        }
        if let def = html.range(of: #"<span class="def">"#),
           let end = endOfElement(in: html, tag: "span", openingAt: def.lowerBound) {
            let inner = html[def.upperBound..<html.index(end, offsetBy: -"</span>".count)]
            let text = plainText(inner)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// 纯桥条目的指向。gave / arose / calves 这类屈折形在 OALDPE 里是**桥**：
    /// 正文只有一句 `past tense of` + 指向原形的 `entry://` 内链（`xt="ptof"`
    /// 那一族），没有任何释义。划词浮窗查到桥等于查了个寂寞（内链还被砍了，
    /// ADR 0011），要跟着词典自己写的箭头跳到真词条。
    ///
    /// 判定用**排除法**，不枚举 xt 值：无 def、无 deft/chn（中译）、却有
    /// `entry://` 引用。全库实测（2026-08-30）：命中 338 条，全是屈折形和
    /// in absentia 式短语指针；16,924 条**带释义**的条目也含交叉引用
    /// （see / syn / opp），绝不能跳——排除法把它们天然挡在外面。
    /// 只解析一跳，跳转本身由调用方执行（要不要跳是壳层的策略）。
    public static func bridgeTarget(for record: String) -> String? {
        guard !record.hasPrefix("@@@LINK=") else { return nil }
        guard !record.contains(#"class="def""#),
              !record.contains("<deft"),
              !record.contains(#"class="chn"#),
              let ref = record.range(of: #"href="entry://"#)
        else { return nil }
        // entry://give#give_1 —— # 后面是锚点，词在前面
        let start = ref.upperBound
        guard let end = record[start...].firstIndex(where: { $0 == "\"" || $0 == "#" })
        else { return nil }
        let target = String(record[start..<end])
        guard !target.isEmpty else { return nil }
        return target.removingPercentEncoding ?? target
    }

    /// 中文词头条目里链接指向的英文词。这类条目分两种：例句表
    /// （`<a href="entry://dupe" title="dupe">整句英文</a>`）和习语直链表
    /// （`<a href="entry://glad#glad_sng_5">be glad…</a>`，没有 title）——
    /// 统一从 href 里取目标词：`#` 后的义项锚点丢掉，URL 编码解回来。
    private static func englishTargets(_ html: String) -> String? {
        var words: [String] = []
        var cursor = html.startIndex
        while words.count < 3,
              let a = html.range(of: #"href="entry://"#, range: cursor..<html.endIndex) {
            guard let q = html[a.upperBound...].firstIndex(of: "\"") else { break }
            cursor = q
            let target = html[a.upperBound..<q]
            let word = String(target.prefix { $0 != "#" }).removingPercentEncoding ?? ""
            if !word.isEmpty, !words.contains(word) { words.append(word) }
        }
        return words.isEmpty ? nil : words.joined(separator: " · ")
    }

    /// 剥掉标签、解常见实体、按正文的规则换标点，收尾去空白。只给预览用——
    /// 正文渲染从不走「剥标签」这条路。
    private static func plainText(_ fragment: Substring) -> String {
        var out = ""
        out.reserveCapacity(fragment.count)
        var inTag = false
        for ch in fragment {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        for (entity, ch) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")]
        where out.contains(entity) {
            out = out.replacingOccurrences(of: entity, with: ch)
        }
        return convertPunctuation(Substring(out))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 词性分节

    /// 把词头和音标上提到最前面，每个词性块降级成词头下面的一节。
    ///
    /// 词典的原始结构是**每个词性各自重复一遍词头**：light 有名词/形容词/动词/副词
    /// 四段，"light" 这个词就出现四次。上提之后词头只出现一次，下面是
    /// NOUN / ADJECTIVE / … 一节一节排下去。各节自己的词头由 CSS 关掉，不删 HTML。
    ///
    /// 音标同理：四节的音标一模一样时只留最上面那份。**只删和第一份完全相同的**——
    /// record 的名词 /ˈrekɔːd/ 和动词 /rɪˈkɔːd/ 不同，各节都得保留自己的。
    ///
    /// 中文词头条目（占实体词条的 72%）没有 `h1.headword`，原样返回。
    static func hoistHeadword(_ html: String) -> String {
        guard let open = html.firstRange(of: /<h1\b[^>]*class="[^"]*headword[^"]*"[^>]*>/),
              let close = html.range(of: "</h1>", range: open.upperBound..<html.endIndex)
        else { return html }
        let word = String(html[open.upperBound..<close.lowerBound])

        var phonetics = ""
        var body = html
        if let p = html.range(of: #"<span class="phonetics">"#, range: close.upperBound..<html.endIndex),
           let e = endOfElement(in: html, tag: "span", openingAt: p.lowerBound) {
            phonetics = String(html[p.lowerBound..<e])
            body = body.replacingOccurrences(of: phonetics, with: "")
        }

        // 词头一行（右端是收藏的星），音标自成一行——星要占词头行最右，
        // 音标留在同一行就没地方放它（用户定的方案 A）。没有音标就不出第二行。
        let hwline = "<div class=\"hwline\"><h1>\(word)</h1>\(favoriteAnchor)</div>"
        let phonline = phonetics.isEmpty
            ? "" : "<div class=\"phonline\">\(phonetics)\(moreReadingsToggle(phonetics))</div>"
        let header = "<header class=\"hw\">\(hwline)\(phonline)</header>"
        guard let bc = body.range(of: "<body-content"),
              let bcEnd = body[bc.lowerBound...].firstIndex(of: ">")
        else { return header + body }
        return String(body[..<body.index(after: bcEnd)]) + header
             + String(body[body.index(after: bcEnd)...])
    }

    // MARK: 义项折叠

    /// 每节留 `keep` 个义项，其余标上 `overflow` 类，并在这一节末尾放一个展开开关。
    ///
    /// **不把多出来的义项包进 `<details>` 里**——它们可能嵌在 `span.shcut-g`（义群）
    /// 内部，从中间切一刀会把标签套错。改成给它们加个类、由 CSS 关掉，
    /// `<details>` 作为 `<ol>` 的**兄弟**放在后面，一个字节的嵌套都不动。
    ///
    /// `<details>` 是原生元素，**不需要 JS**——正文里的脚本全被拦掉了（ADR 0009）。
    static func collapseExtraSenses(_ html: String, keep: Int) -> String {
        let marker = #"<ol class="senses_multiple">"#
        let child  = #"<div class="li_sense">"#
        var out = ""
        var cursor = html.startIndex

        while let ol = html.range(of: marker, range: cursor..<html.endIndex) {
            guard let olEnd = endOfElement(in: html, tag: "ol", openingAt: ol.lowerBound) else { break }
            let content = html[ol.upperBound..<html.index(olEnd, offsetBy: -"</ol>".count)]

            var senses: [Range<String.Index>] = []
            var scan = content.startIndex
            while let d = content.range(of: child, range: scan..<content.endIndex) {
                senses.append(d); scan = d.upperBound
            }

            out += html[cursor..<ol.upperBound]
            if senses.count > keep {
                var last = content.startIndex
                for (i, position) in senses.enumerated() {
                    out += content[last..<position.lowerBound]
                    out += i < keep ? child : #"<div class="li_sense overflow">"#
                    last = position.upperBound
                }
                out += content[last...]
                // 超过 6 个隐藏义项的节标成 big：收起时 CSS 不做行高动画（改为
                // 淡出后一次合拢）。全量收拢动画在大节上会闪出布局白洞——
                // 视口上方十几屏内容同时缩高，中途文档比滚动位置还短。
                let hidden = senses.count - keep
                let cls = hidden > 6 ? "more big" : "more"
                out += "</ol><details class=\"\(cls)\"><summary data-n=\"\(hidden)\"></summary></details>"
            } else {
                out += content + "</ol>"
            }
            cursor = olEnd
        }
        out += html[cursor...]
        return out
    }

    /// 从 `openingAt` 处的开标签数到它自己的闭标签，返回闭标签之后的位置。
    /// 同名标签会嵌套（`<span class="unbox">` 里全是 `<span>`），必须计深度。
    private static func endOfElement(in html: String, tag: String, openingAt start: String.Index) -> String.Index? {
        let open = "<\(tag)", close = "</\(tag)>"
        var depth = 0
        var cursor = start
        while cursor < html.endIndex {
            let nextOpen = html.range(of: open, range: cursor..<html.endIndex)
            let nextClose = html.range(of: close, range: cursor..<html.endIndex)
            guard let nextClose else { return nil }
            if let nextOpen, nextOpen.lowerBound < nextClose.lowerBound {
                depth += 1
                cursor = nextOpen.upperBound
            } else {
                depth -= 1
                if depth == 0 { return nextClose.upperBound }
                cursor = nextClose.upperBound
            }
        }
        return nil
    }
}
