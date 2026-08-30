import DictIndex
@testable import DictRender
import Foundation
import Testing
@testable import MDictKit

/// M3 渲染变换。这里守两类错：
/// 一是**该剥的没剥干净**（脚本漏一个就能跟 iOS 长按选词抢事件）；
/// 二是**变换把内容弄没了**——解析层的校验和管不到这一层，词条少一段中译
/// 不会抛任何错，只会在屏幕上少一行。
struct RenderTests {

    static func table() throws -> KeyTable? {
        try KeyTableTests.table(for: GoldenTests.goldens.dictionaries[0])
    }

    // MARK: 剥危险物

    @Test("脚本、外链样式、内联样式、事件属性一个不剩")
    func hazardsAreStripped() throws {
        guard let table = try Self.table() else { return }
        for word in ["abandon", "run", "serendipity", "上当"] {
            guard let match = try table.lookup(word).first else { continue }
            #expect(match.html.contains("<script"), "\(word) 的原始正文本来就该带脚本")

            let out = EntryRenderer.transform(match.html)
            #expect(!out.contains("<script"), "\(word) 残留 <script")
            #expect(!out.contains("<link"),   "\(word) 残留 <link")
            #expect(!out.contains("style=\""), "\(word) 残留内联样式")
            #expect(!out.contains(/\son[a-z]+="/), "\(word) 残留事件属性")
        }
    }

    @Test("全库抽样：没有任何词条靠内联 display:none 藏内容")
    func noInlineHiding() throws {
        // 如果有，剥掉内联样式就会把本该隐藏的东西放出来，或者反过来——
        // 换一部词典时这条要重新跑。实测 OALDPE 抽 1,639 条命中 0 次。
        guard let table = try Self.table() else { return }
        let dict = table.dictionary
        var offenders: [String] = []
        for i in stride(from: 0, to: dict.keyCount, by: max(1, dict.keyCount / 1500)) {
            let html = try dict.recordText(at: i)
            if html.contains("display:none") || html.contains("display: none") {
                offenders.append(dict.key(at: i))
            }
        }
        #expect(offenders.isEmpty, "带内联 display:none 的词条：\(offenders.prefix(5))")
    }

    // MARK: 02 音节点

    @Test("词头去掉音节分隔点，但 syllable 属性留着")
    func syllableDots() throws {
        guard let table = try Self.table(), let match = try table.lookup("abandon").first else { return }
        let out = EntryRenderer.transform(match.html)
        #expect(out.contains(">abandon</h1>"), "词头正文应当是 abandon")
        #expect(!out.contains(">a\u{00B7}ban\u{00B7}don</h1>"))
        // 属性不动——哪天想把音节点放回来，依据还在。
        #expect(out.contains("syllable=\"a\u{00B7}ban\u{00B7}don\""))
    }

    @Test("h1 里嵌 hm / st 标签时音节点照样去掉，子标签一个字节不动")
    func syllableDotsWithNestedSpans() {
        // 同形词（buffet¹²）和人名（A E Hous·man）的 h1 不是纯文本，
        // 按 [^<]* 匹配的旧正则整个失配——实拍词头是「buf·fet1」。
        let hm = #"<h1 class="headword" id="b" syllable="buf·fet">buf·fet<span class="hm">1</span></h1>"#
        #expect(EntryRenderer.removeSyllableDots(hm)
            == #"<h1 class="headword" id="b" syllable="buf·fet">buffet<span class="hm">1</span></h1>"#)
        let st = #"<h1 class="headword" syllable="Hous·man"><span class="st" id="s">A E</span> Hous·man</h1>"#
        #expect(EntryRenderer.removeSyllableDots(st)
            == #"<h1 class="headword" syllable="Hous·man"><span class="st" id="s">A E</span> Housman</h1>"#)
    }

    @Test("同形词 buffet：上提词头没有音节点，hm 号还在（由 CSS 隐藏）")
    func homographHeadwordClean() throws {
        guard let table = try Self.table(), let match = try table.lookup("buffet").first else { return }
        let out = EntryRenderer.transform(match.html)
        #expect(out.contains(#"<header class="hw"><div class="hwline"><h1>buffet<span class="hm">"#),
                "上提词头应当是干净的 buffet + hm 标签")
        #expect(!out.contains(">buf\u{00B7}fet<"), "还有没去掉的音节点")
    }

    // MARK: 33 动词形式拍平

    @Test("动词形式按值去重后平铺")
    func verbFormsFlattened() throws {
        guard let table = try Self.table() else { return }

        func forms(_ word: String) throws -> String? {
            guard let match = try table.lookup(word).first else { return nil }
            let out = EntryRenderer.transform(match.html)
            guard let open = out.range(of: #"<div class="vforms">"#),
                  let close = out.range(of: "</div>", range: open.upperBound..<out.endIndex)
            else { return nil }
            return String(out[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "<i>·</i>", with: "·")
        }

        // 98% 的动词 past 与 pastpart 相同，不去重会连着出现两个 abandoned。
        #expect(try forms("abandon") == "abandon·abandons·abandoned·abandoning")
        // run 的 pastpart 与原形重复，去重后是四项。
        #expect(try forms("run") == "run·runs·ran·running")
        // 不规则动词该保留的一个都不少。
        #expect(try forms("go") == "go·goes·went·gone·going")
        // 名词没有动词形式，不该凭空造一行。
        #expect(try forms("serendipity") == nil)
    }

    @Test("属性顺序变了也要认出折叠块")
    func verbFormAnchorIsAttributeNotTag() throws {
        // class 在前和 id 在前两种写法在同一部词典里都存在，按整段开标签匹配会漏掉一半。
        let a = #"<div class="collapse"><span class="unbox" unbox="verbforms"><table><tr><td class="verb_form"> <span class="vf_prefix">p</span> aa</td></tr><tr><td class="verb_form"> <span class="vf_prefix">q</span> bb</td></tr></table></span></div>"#
        let b = #"<div class="collapse"><span class="unbox" id="x_1" unbox="verbforms"><table><tr><td class="verb_form"> <span class="vf_prefix">p</span> aa</td></tr><tr><td class="verb_form"> <span class="vf_prefix">q</span> bb</td></tr></table></span></div>"#
        for html in [a, b] {
            let out = EntryRenderer.transform(html)
            #expect(out.contains(#"<div class="vforms">aa<i>·</i>bb</div>"#))
            #expect(!out.contains("verbforms"), "折叠块本体要删掉")
        }
    }

    @Test("抽不到值就原样放过，不弄坏版式")
    func flatteningFailsSafe() {
        let broken = #"<span class="unbox" unbox="verbforms"><table><tr><td>没有 verb_form 类</td></tr></table></span>"#
        #expect(EntryRenderer.transform(broken).contains("没有 verb_form 类"))
        #expect(!EntryRenderer.transform(broken).contains("vforms"))
    }

    // MARK: 中文标点

    @Test("全角括号换半角，只在贴着汉字的一侧补空格")
    func parentheses() {
        func t(_ s: String) -> String { EntryRenderer.halfWidthPunctuation(s) }
        #expect(t("（不顾责任）离弃") == "(不顾责任) 离弃")          // 收括号后面是汉字 → 补
        #expect(t("弃船（因船沉没）。") == "弃船 (因船沉没)。")       // 开括号前是汉字 → 补；句号前不补
        #expect(t("（正式用语）") == "(正式用语)")                   // 首尾都不补
        #expect(t("a（b）c") == "a(b)c")                            // 两侧都不是汉字 → 一个空格都不补
        // **标签内部一个字节都不许动**：属性值里也可能有全角括号。
        #expect(t(#"<span title="（英）">中文（注）</span>"#) == #"<span title="（英）">中文 (注)</span>"#)
    }

    @Test("全角逗号分号换半角，后面一律补空格")
    func commas() {
        func t(_ s: String) -> String { EntryRenderer.halfWidthPunctuation(s) }
        #expect(t("英式英语，非正式用语") == "英式英语, 非正式用语")
        #expect(t("甲；乙；丙") == "甲; 乙; 丙")
        #expect(t("别急，埃米莉！") == "别急, 埃米莉！")             // 只换这两个，其余全角标点不动
        #expect(t("独自，单独") == "独自, 单独")
        #expect(t("甲， 乙") == "甲, 乙")                           // 已经有空格 → 不叠加
        #expect(t("粗鲁地 ，下流地") == "粗鲁地, 下流地")            // 源头带前置空格 → 吃掉
        // 文本节点末尾的也补：句子在标签边界上继续。实测这种有两万处。
        #expect(t("英式英语，<span>非正式</span>") == "英式英语, <span>非正式</span>")
        // 属性值里的一个字节不许动。实测全库 1,075 处。
        #expect(t(#"<a title="甲，乙">丙，丁</a>"# ) == #"<a title="甲，乙">丙, 丁</a>"#)
        // 和括号规则叠在一起时不能多补空格。
        #expect(t("（甲）乙，（丙）") == "(甲) 乙, (丙)")
        #expect(t("甲，（乙）") == "甲, (乙)")
    }

    @Test("只动释义，例句一个字节不动")
    func punctuationSkipsExamples() {
        func t(_ s: String) -> String { EntryRenderer.halfWidthPunctuation(s) }

        // 释义改，同一条里的例句不改。
        let sense = #"<deft><chn>离弃，遗弃</chn></deft><ul class="examples"><li>"#
            + #"<span class="x">A.<xt><chn>他舍弃了土地，走了。</chn></xt></span></li></ul>"#
        #expect(t(sense) == #"<deft><chn>离弃, 遗弃</chn></deft><ul class="examples"><li>"#
            + #"<span class="x">A.<xt><chn>他舍弃了土地，走了。</chn></xt></span></li></ul>"#)

        // 例句表里再嵌 <ul> 也还在例句里；出了最外层那个 </ul> 才恢复。
        let nested = #"<ul class="examples"><ul class="bullet"><chn>甲，乙</chn></ul>"#
            + #"<chn>丙，丁</chn></ul><deft>戊，己</deft>"#
        #expect(t(nested) == #"<ul class="examples"><ul class="bullet"><chn>甲，乙</chn></ul>"#
            + #"<chn>丙，丁</chn></ul><deft>戊, 己</deft>"#)

        // 不在例句表里的 <xt>/<unxt> 也是例句中译。
        #expect(t("<unxt>甲，乙</unxt>丙，丁") == "<unxt>甲，乙</unxt>丙, 丁")

        // 中文词头的例句列表：整条都是例句，连词头一起放过。
        let zhEx = #"<div class="leon-zh-en examples"><div class="headw">上当</div>"#
            + #"<span class="zh">他上当了，很生气。</span></div>"#
        #expect(t(zhEx) == zhEx)
        // 中文词头的**释义**列表长得几乎一样，但它是释义，要改。
        #expect(t(#"<div class="leon-zh-en"><span class="zh">β 版，测试版</span></div>"#)
             == #"<div class="leon-zh-en"><span class="zh">β 版, 测试版</span></div>"#)
    }

    // MARK: 发音按钮

    @Test("音标挪进喇叭的 <a> 里，整段可点")
    func phoneticsWrapped() {
        let html = #"<div class="phons_br"><a class="sound pron-uk" href="sound://x.mp3"></a><span class="phon">/eks/</span></div>"#
        let out = EntryRenderer.wrapPhoneticsInButton(html)
        #expect(out == #"<div class="phons_br"><a class="sound pron-uk" href="sound://x.mp3"><span class="phon">/eks/</span></a></div>"#)
    }

    @Test("世界英语读音组：地区名和音标挪进喇叭里，名字换成中文短标签")
    func worldEnglishPhonetics() {
        // gatvol（南非英语）的真实形态：喇叭是空标签，地区名和音标都在它后面。
        // 不挪的话喇叭宽度为零点不到，这组发音根本放不出来。
        let html = #"<div class="phons_we" spkricon="world_english"><a class="sound audio_play_button pron-us icon-audio" href="sound://gatvol__sa_1.mp3" valign="top"></a><span class="phon_label">South African English </span><span class="phon">[ˈxɐtfɔl]</span></div>"#
        let out = EntryRenderer.wrapPhoneticsInButton(html)
        #expect(out.contains(#"<span class="phon_label">南非</span><span class="phon">[ˈxɐtfɔl]</span></a>"#),
                "地区名 + 音标应当在 </a> 之前、且译成中文")
        #expect(!out.contains("South African"), "英文地区名应当被换掉")
        // 不认识的地区名原样保留，照样挪进去。
        let unknown = #"</a><span class="phon_label">Martian English</span><span class="phon">[x]</span>"#
        let out2 = EntryRenderer.wrapPhoneticsInButton(unknown)
        #expect(out2.contains(#"<span class="phon_label">Martian English</span><span class="phon">[x]</span></a>"#))
    }

    @Test("一个地区多个读法时各自成一段")
    func multiplePronunciations() throws {
        guard let table = try Self.table() else { return }
        // either 的英式有 /ˈaɪðə(r)/ 和 /ˈiːðə(r)/ 两个读法，各指向不同的音频文件
        let out = EntryRenderer.transform(try table.lookup("either").first!.html)
        let buttons = out.ranges(of: #"<a class="sound"#).count
        #expect(buttons >= 4, "either 应当有四段发音，实际 \(buttons)")
        // 挪干净了：不该再有「空的 </a> 后面跟着一个音标」这种形态。
        // 例句里的 a.sound 本来就是空的（没有音标兄弟），它们不在这条约束里。
        #expect(!out.contains(#"</a><span class="phon">"#), "还有音标没挪进按钮")
    }

    @Test("strong form 这类限定语挪进它限定的那一段里")
    func strongFormPrefixMovesIntoButton() throws {
        guard let table = try Self.table() else { return }
        // and / of / was 这类虚词有弱读和强读两套，词典把 <span class="prefix">strong
        // form</span> 放在**后面**那个读法的前面、按钮之外。留在外面它就是分段控件里
        // 一段游离的散文，把整行挤变形。
        for word in ["and", "of", "was"] {
            let out = EntryRenderer.transform(try table.lookup(word).first!.html)
            #expect(out.contains(#"<span class="prefix">"#), "\(word) 的限定语被吃掉了")
            // 挪进去了：prefix 紧跟在 <a class="sound…"> 后面，不再是它的兄弟。
            #expect(out.matches(of: /<a class="sound[^>]*><span class="prefix">/).count >= 2,
                    "\(word) 的 strong form 还在按钮外面")
            #expect(out.matches(of: /<span class="prefix">[^<]*<\/span>\s*<a class="sound/).isEmpty,
                    "\(word) 还有 prefix 留在按钮前面")
        }
    }

    @Test("多读音的词头带一个「更多读音」开关，读法没被删")
    func moreReadingsToggle() throws {
        guard let table = try Self.table() else { return }
        // 实测 95.33% 的词条正好「英 1 + 美 1」，这些不该有开关。
        for word in ["schedule", "abandon", "hippocampus"] {
            let out = EntryRenderer.transform(try table.lookup(word).first!.html)
            #expect(!out.contains("morephon"), "\(word) 只有两个读音，不该有开关")
        }
        // 有第三个读音的才有，data-n 是"第一个之外还剩几个"，两个地区各自算。
        for (word, extra) in [("garage", 3), ("either", 2), ("and", 6), ("controversy", 1)] {
            let out = EntryRenderer.transform(try table.lookup(word).first!.html)
            #expect(out.contains(#"<label class="morephon" data-n="\#(extra)">"#),
                    "\(word) 的开关计数不是 \(extra)")
            // **一个读法都没删**——藏是 CSS 的事，标记里全在。
            let sounds = out.ranges(of: #"<a class="sound"#).count
            #expect(sounds >= extra + 2, "\(word) 的读法被删掉了，只剩 \(sounds) 个")
        }
        // 开关不带 id：同名词头有多条时几份正文会拼进同一个文档，id 会撞。
        let out = EntryRenderer.transform(try table.lookup("garage").first!.html)
        #expect(!out.contains(#"<label class="morephon" id"#))
        #expect(out.contains("<label class=\"morephon\" data-n=\"3\"><input type=\"checkbox\"></label>"))
    }

    @Test("变形自己的音标不参与词头发音")
    func inflectionPhoneticsStayInBlock() throws {
        guard let table = try Self.table() else { return }
        let out = EntryRenderer.transform(try table.lookup("hippocampus").first!.html)
        // 复数 hippocampi 的两个读法各带英美，加上词头的两颗——不处理就是六颗按钮。
        // 数据不删，靠 CSS 关掉，所以这里断言它们确实都在 .inflections 块**内**。
        let block = try #require(out.range(of: #"<div class="inflections""#))
        // 变形块在文档顺序上排在词头音标之后，所以「它之前的按钮」就是词头那些。
        // 只数带音标的——例句里的 a.sound 是空标签（由 .h19 关掉），不算。
        let head = out[..<block.lowerBound]
        let buttons = head.matches(of: /<a class="sound[^>]*><span class="phon"/).count
        #expect(buttons == 2, "词头有 \(buttons) 颗发音按钮，应该是英式美式各一颗")
        // 复数的四颗确实在变形块里，没被上提逻辑当成词头音标搬走
        #expect(out.matches(of: /<a class="sound[^>]*><span class="phon"/).count == 6)
    }

    // MARK: 词性分节与义项折叠

    @Test("词头和音标上提一份，各节自己那份不再重复")
    func headwordHoisted() throws {
        guard let table = try Self.table() else { return }
        let out = EntryRenderer.transform(try table.lookup("light").first!.html)

        // 上提出来的那份在最前面：词头行（带收藏星）+ 音标行
        #expect(out.contains("<header class=\"hw\"><div class=\"hwline\"><h1>light</h1><a class=\"fav\""))
        #expect(out.contains("<div class=\"phonline\"><span class=\"phonetics\">"))
        // 四个词性的音标都是 /laɪt/，只留一份
        #expect(out.ranges(of: #"<span class="phonetics">"#).count == 1)
        // 词性块自己的 h1 **不删**，只靠 CSS 关掉——将来想恢复不用改渲染层
        #expect(out.ranges(of: "class=\"headword\"").count >= 4 || out.contains("headword"))
    }

    @Test("音标不同的词性各留各的")
    func differingPhoneticsKept() throws {
        guard let table = try Self.table() else { return }
        // record 的名词 /ˈrekɔːd/ 和动词 /rɪˈkɔːd/ 不同，不能只留一份
        guard let m = try table.lookup("record").first else { return }
        let out = EntryRenderer.transform(m.html)
        #expect(out.ranges(of: #"<span class="phonetics">"#).count >= 2,
                "重音位置不同的词性被合并了")
    }

    @Test("变形自己带的音标不算词头的音标")
    func inflectionPhoneticsNotCountedAsHeadword() throws {
        guard let table = try Self.table() else { return }
        // hippocampus 的复数 hippocampi 有两个读法，各带英式美式——连同词头的两行，
        // 屏幕上会出现四行音标，看着像这个词有四个读音。
        let out = EntryRenderer.transform(try table.lookup("hippocampus").first!.html)
        guard let block = out.range(of: #"<div class="inflections""#),
              let end = out.range(of: "</div>", range: block.upperBound..<out.endIndex)
        else { Issue.record("hippocampus 应该有变形块"); return }
        // 变形块里的音标不删（数据不动），由 CSS 关掉——所以这里只断言它确实在块**内**，
        // 没有漏到词头那一份里去。
        #expect(out[block.lowerBound..<end.upperBound].contains(#"<span class="phonetics">"#))
        #expect(out.ranges(of: #"<span class="phonetics">"#).count == 2)
    }

    @Test("中文词头条目没有 h1，原样放过")
    func chineseEntriesUntouched() throws {
        guard let table = try Self.table() else { return }
        let out = EntryRenderer.transform(try table.lookup("上当").first!.html)
        #expect(!out.contains("<header class=\"hw\">"))
        #expect(out.contains("class=\"headw\""))
    }

    @Test("每节留两个义项，其余标记折叠")
    func sensesCollapsed() throws {
        guard let table = try Self.table() else { return }
        let out = EntryRenderer.transform(try table.lookup("light").first!.html)

        let hidden = out.ranges(of: #"<div class="li_sense overflow">"#).count
        #expect(hidden > 0, "light 义项很多，应该有折叠")
        // 一个 ol.senses_multiple 最多配一个开关（少于三个义项的那些不配）
        let groups = out.ranges(of: #"<ol class="senses_multiple">"#).count
        let toggles = out.ranges(of: #"<details class="more">"#).count
            + out.ranges(of: #"<details class="more big">"#).count
        #expect(toggles > 0 && toggles <= groups)
        // 开关条数要和被折叠的义项数对得上；折叠数 > 6 的节要标 big
        // （收起动画按规模分流），light 的形容词节 17 个就是这种。
        let counts = out.matches(of: /<details class="(more|more big)"><summary data-n="(\d+)">/)
            .map { (big: $0.1 == "more big", n: Int($0.2)!) }
        #expect(!counts.isEmpty)
        #expect(counts.map(\.n).reduce(0, +) == hidden, "展开按钮上的条数和实际折叠的义项数对不上")
        for c in counts { #expect(c.big == (c.n > 6), "data-n=\(c.n) 的 big 标记不对") }
        #expect(counts.contains { $0.big }, "light 该有超过 6 条的大节")
    }

    @Test("义项不超过两个就不加展开按钮")
    func noToggleWhenShort() {
        let two = #"<ol class="senses_multiple"><div class="li_sense">a</div><div class="li_sense">b</div></ol>"#
        let out = EntryRenderer.collapseExtraSenses(two, keep: 2)
        #expect(!out.contains("details"))
        #expect(!out.contains("overflow"))
    }

    @Test("折叠不动标签嵌套")
    func collapseKeepsNesting() {
        // 多出来的义项嵌在 span.shcut-g（义群）里——包进 <details> 会把标签套错，
        // 所以只加类、开关放在 </ol> 外面。
        let html = #"<ol class="senses_multiple"><span class="shcut-g"><div class="li_sense">1</div><div class="li_sense">2</div><div class="li_sense">3</div></span></ol>"#
        let out = EntryRenderer.collapseExtraSenses(html, keep: 2)
        #expect(out.contains(#"</span></ol><details class="more">"#))
        #expect(out.contains(#"<div class="li_sense overflow">3</div>"#))
        #expect(out.contains(#"<summary data-n="1">"#))
    }

    // MARK: 内容不能丢

    @Test("变换不吞内容", arguments: ["abandon", "run", "上当", "dictionary"])
    func contentSurvives(_ word: String) throws {
        guard let table = try Self.table(), let match = try table.lookup(word).first else { return }
        let out = EntryRenderer.transform(match.html)

        func count(_ needle: String, in text: String) -> Int {
            text.ranges(of: needle).count
        }
        // 释义和例句的条数必须**分毫不差**。少一条不会抛错、不会崩，
        // 只会在屏幕上少一行——记录块的校验和管不到这一层。
        for marker in [#"<span class="x">"#, "<xt>", "<deft>"] {
            #expect(count(marker, in: out) == count(marker, in: match.html),
                    "\(word) 的 \(marker) 数量变了")
        }

        // 中文节点只允许少一个，且只在拍平了动词形式时——那一个是被拍掉的折叠块
        // 自己的标题「动词形式」，它本来就该跟着盒子走。多于一个就是真吞了内容。
        let lost = count(#"<chn class="simple">"#, in: match.html) - count(#"<chn class="simple">"#, in: out)
        let flattened = out.contains(#"<div class="vforms">"#)
        #expect(lost == (flattened ? 1 : 0), "\(word) 少了 \(lost) 个中文节点")
    }

    // MARK: 文档外壳

    @Test("文档挂上三张样式表和全部开关类")
    func documentShell() {
        let doc = EntryRenderer.document(for: "<body><body-content class=\"oaldpe\">x</body-content></body>")
        for sheet in ["entry.css", "oaldpe-map.css", "hidden.css"] {
            #expect(doc.contains("dict://asset/\(sheet)"))
        }
        let switches = EntryRenderer.Options.standard.hidden.sorted().map { "h\($0)" }.joined(separator: " ")
        #expect(doc.contains("class=\"oa10 \(switches) renum ex1\""))
        // 07 拼写变体 `(also Test match)`：纯英文、没有中文对照，隐藏。
        #expect(EntryRenderer.Options.standard.hidden.contains(7))
        // 29 同形异义分栏**不隐藏**：那条分隔线是「看得出换词性了」的唯一线索。
        #expect(!EntryRenderer.Options.standard.hidden.contains(29))
        #expect(doc.contains("viewport-fit=cover"))
        // 隐藏是可逆的：换一组开关，根 class 立刻跟着变，数据一个字节没动。
        let raw = EntryRenderer.document(for: "<body><body-content>x</body-content></body>", options: .raw)
        #expect(raw.contains("class=\"oa10\""))
        // 界面状态类（收藏态）从 extraRootClasses 进来，挂在根元素上。
        let faved = EntryRenderer.document(for: "<body><body-content>x</body-content></body>",
                                           options: .raw, extraRootClasses: ["faved"])
        #expect(faved.contains("class=\"oa10 faved\""))
    }

    @Test("短语动词的变体标题一行一个式子")
    func pvVariantsStack() {
        let t = EntryRenderer.stackPhrasalVariants
        #expect(t(#"<span class="pv" id="x">turn around | turn somebody/something around</span>"#)
             == #"<span class="pv" id="x">turn around<br>turn somebody/something around</span>"#)
        // 单式子（92%）不动
        #expect(t(#"<span class="pv">take after somebody</span>"#)
             == #"<span class="pv">take after somebody</span>"#)
        // pv-g 的 span 和别处的 | 都不碰
        #expect(t(#"<span class="pv-g">a | b</span>"#) == #"<span class="pv-g">a | b</span>"#)
        #expect(t(#"<span class="x">a | b</span><span class="pv">c | d</span>"#)
             == #"<span class="x">a | b</span><span class="pv">c<br>d</span>"#)
    }

    @Test("式子和词头一模一样的 pv 打上 pv-dup，多式子的不动")
    func pvDupMarking() {
        func t(_ s: String) -> String {
            EntryRenderer.markDuplicatePhrasalVariants(EntryRenderer.stackPhrasalVariants(s))
        }
        let hw = #"<h1 class="headword" id="x_h_1">boogie down</h1>"#
        // 整行 == 词头 → 打类
        #expect(t(hw + #"<span class="pv" id="a">boogie down</span>"#)
             == hw + #"<span class="pv pv-dup" id="a">boogie down</span>"#)
        // 多式子里有一个 == 词头 → 不动（那是「可以不及物」的信息）
        #expect(t(hw + #"<span class="pv">boogie down | boogie down something</span>"#)
             == hw + #"<span class="pv">boogie down<br>boogie down something</span>"#)
        // 式子 != 词头 → 不动
        #expect(t(hw + #"<span class="pv">boogie down somebody</span>"#)
             == hw + #"<span class="pv">boogie down somebody</span>"#)
    }

    // MARK: 收藏按钮

    @Test("收藏星：上提词条、中文词头、独立习语各正好一颗，没词头的原样放过")
    func favoriteButtonInjection() throws {
        guard let table = try Self.table() else { return }
        // light 走上提（星在 hwline 里）；上当是 .headw；take (a) hold 是 idm-g 独立习语
        for word in ["light", "上当", "take (a) hold"] {
            let out = EntryRenderer.transform(try #require(try table.lookup(word).first).html)
            #expect(out.ranges(of: #"class="fav""#).count == 1, "\(word) 应当正好一颗星")
            #expect(out.contains(#"href="fav://toggle""#), "\(word)")
        }
        #expect(EntryRenderer.injectFavoriteButton("<p>没有词头的页面</p>")
                == "<p>没有词头的页面</p>")
    }

    // MARK: 释义预览

    @Test("预览：英文词条取第一条释义的中文，标点换半角")
    func previewEnglish() throws {
        guard let table = try Self.table() else { return }
        #expect(EntryRenderer.preview(for: try #require(try table.lookup("buffet").first).html)
                == "自助餐")
        #expect(EntryRenderer.preview(for: try #require(try table.lookup("abandon").first).html)
                == "(不顾责任、义务等) 离弃, 遗弃, 抛弃")
    }

    @Test("预览：中文词头取指向的英文词，例句表和习语直链两种形都认")
    func previewChineseHeadword() throws {
        guard let table = try Self.table() else { return }
        // 例句表：<a href="entry://dupe" title="dupe">整句英文</a>
        #expect(EntryRenderer.preview(for: try #require(try table.lookup("上当").first).html)
                == "dupe · victim · crowd")
        // 习语直链：<a href="entry://glad#glad_sng_5">，没有 title 属性
        #expect(EntryRenderer.preview(for: try #require(try table.lookup("高兴").first).html)
                == "glad · people · rapture")
    }

    @Test("预览：deft 的中文优先，没有中译退回英文 def，重定向记录不出预览")
    func previewFallbacks() {
        let withDeft = #"<body-content><span class="def">a thing</span>"# +
            #"<deft><chn class="simple">（东西），物</chn><chn class="traditional">物</chn></deft>"# +
            #"</body-content>"#
        #expect(EntryRenderer.preview(for: withDeft) == "(东西), 物")

        let noDeft = #"<body-content><span class="def">only <i>English</i> here</span></body-content>"#
        #expect(EntryRenderer.preview(for: noDeft) == "only English here")

        #expect(EntryRenderer.preview(for: "@@@LINK=take-off") == nil)
        #expect(EntryRenderer.preview(for: "<body-content><p>什么都没有</p></body-content>") == nil)
    }

    /// 习语和短语动词本身也能是独立词条：`take (a) hold` 的根就是 `span.idm-g`、
    /// 外面没有 `.entry`；`turn around` 的正文整个是 `pv-g`（实测 pv-g 只存在于
    /// 独立词条，主词条内嵌 0 条）。24/25 的隐藏规则只能藏主词条**里面**的区块——
    /// `.h24 .idm-g` 会把独立习语整条藏掉（抽样 1.9%），`.h25 .pv-g` 会把独立
    /// 短语动词掏成「词头在、释义空」（抽样 0.7%）。都不报错。
    @Test("隐藏层不能藏掉独立的习语/短语动词词条")
    func hiddenDoesNotKillIdiomEntries() throws {
        let css = try String(contentsOf: GoldenTests.repoRoot.appending(path: "App/Resources/hidden.css"),
                             encoding: .utf8)
        // 把每条规则的选择器拆出来，逐个看含 .idm-g 的都有 .entry 或 .idioms 这层祖先
        // 注释先剥干净——里面写着 .pv-g 的«反例»，不剥会被当成选择器。
        var stripped = css
        while let open = stripped.range(of: "/*"),
              let close = stripped.range(of: "*/", range: open.upperBound..<stripped.endIndex) {
            stripped.removeSubrange(open.lowerBound..<close.upperBound)
        }
        var idmSelectors: [String] = []
        var pvSelectors: [String] = []
        for rule in stripped.split(separator: "}") {
            guard let head = rule.split(separator: "{").first else { continue }
            for part in head.split(separator: ",") {
                let s = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.contains(".idm-g") { idmSelectors.append(s) }
                if s.contains(".pv-g") { pvSelectors.append(s) }
            }
        }
        #expect(!idmSelectors.isEmpty)
        for s in idmSelectors {
            #expect(s.contains(".entry ") || s.contains(".idioms "), "\(s) 会藏掉独立习语词条")
        }
        #expect(pvSelectors.isEmpty, "pv-g 只存在于独立短语动词词条，藏它就是藏词条")
    }
}
