import Foundation
import NaturalLanguage

/// 划词入口的查询归一化。
///
/// 划中的文本和键入的查询不是一种东西：实测 30 个划词样例（2026-08-30，真词典），
/// 屈折形全部命中（OALDPE 自带 ran/children 这类词条，约半数是 @@@LINK），
/// **未命中的只有两类**——①带着首尾标点/弯引号/所有格进来的（`word.`、`“word”`、
/// `word’s`），②屈折了的短语（`gave up` 查不到、`give up` 查得到）。
/// 这里按命中概率产出一列候选查询，调用方逐个试到第一个命中为止：
///
///     原样修剪 → 剥所有格 → 逐词还原词形（NLTagger，离线）→ 首词 → 首词还原
///
/// 键入路径（搜索框）不走这里——候选列表本身就是它的容错。
public enum QueryNormalizer {

    /// 有序、去重的候选查询。空白/纯标点的输入返回空数组。
    public static func candidates(for raw: String) -> [String] {
        let trimmed = trim(raw)
        guard !trimmed.isEmpty else { return [] }

        var out = [trimmed]
        let bare = stripPossessive(trimmed)
        out.append(bare)
        if let lemma = lemmatize(bare) { out.append(lemma) }

        // 短语整体不中时降级到首词——划一句话查第一个词，比什么都查不到强。
        let words = bare.split(separator: " ")
        if words.count > 1, let first = words.first.map(String.init) {
            out.append(first)
            if let lemma = lemmatize(first) { out.append(lemma) }
        }

        var seen = Set<String>()
        return out.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 首尾修剪：空白 + 标点 + 符号（弯直引号都是标点）。只修两端，
    /// `state-of-the-art` 中间的连字符不受影响。
    static func trim(_ text: String) -> String {
        let junk = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return text.trimmingCharacters(in: junk)
    }

    /// 剥所有格：`word's` / `word’s` → word，`words'` → words。
    /// 注意 `don't` / `it's` 是正经词条（实测命中），所以只剥**尾部**的
    /// 所有格记号，绝不动词中间的撇号。
    static func stripPossessive(_ text: String) -> String {
        for suffix in ["'s", "’s"] where text.hasSuffix(suffix) {
            return String(text.dropLast(2))
        }
        for suffix in ["'", "’"] where text.hasSuffix(suffix) {
            return String(text.dropLast(1))
        }
        return text
    }

    /// 逐词还原词形后按原分隔拼回：`gave up` → `give up`。
    /// 全程离线（NaturalLanguage 自带模型）。还原不出（中文、专名、本来就是
    /// 原形）返回 nil，让调用方跳过重复候选。
    static func lemmatize(_ text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        var pieces: [String] = []
        var changed = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let original = String(text[range])
            if let lemma = tag?.rawValue, !lemma.isEmpty, lemma != original {
                pieces.append(lemma)
                changed = true
            } else {
                pieces.append(original)
            }
            return true
        }
        guard changed else { return nil }
        let joined = pieces.joined(separator: " ")
        return joined == text ? nil : joined
    }
}
