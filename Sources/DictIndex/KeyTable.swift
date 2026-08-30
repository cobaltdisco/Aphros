import Foundation
import MDictKit

/// 词头查询表：精确查、前缀查、子串查。
///
/// **不复用 mdx 自己的键序。** 实测：OALDPE 的 46.4 万词头按 ASCII 折叠后严格有序，
/// 但 cecd2024 有 11,579 处乱序、oxfordadvanced 有 10,881 处。MdxBuilder 各版本的比较器
/// 并不一致，拿它二分等于赌运气——赌输了是「查不到这个词」，不报错。
/// 所以这里全量吃进词头，按**自己定义的归一化**重排一遍，查询走同一条归一化路径。
public struct KeyTable: Sendable {

    /// 按归一化词头升序排列的条目号。同归一化键的多条按原始顺序排（稳定）。
    public let order: [UInt32]
    /// 含大写 ASCII 字母的条目号。实测 OALDPE 只有 1,042 / 463,860 条，
    /// 子串搜索时单独兜这一小撮，就不必为整块 blob 再存一份折叠副本（省 5.7 MB）。
    public let mixedCase: [UInt32]

    public let dictionary: MDict

    // MARK: 归一化

    /// 查询和词头走**同一条**归一化：去掉首尾 ASCII 空白，A–Z 降为 a–z。
    ///
    /// 刻意**不剥标点**。OALDPE 的 `StripKey` 是 `No`，而实测按「剥标点 + 小写」排序会
    /// 产生 13,800 处乱序——ADR 0002 里 mdict-cpp 30% 查错就是替词典做了它没要求的 strip。
    @inlinable
    public static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte
    }

    public static func normalize(_ query: String) -> [UInt8] {
        var bytes = Array(query.utf8)
        while let f = bytes.first, f == 0x20 || f == 0x09 || f == 0x0A || f == 0x0D { bytes.removeFirst() }
        while let l = bytes.last,  l == 0x20 || l == 0x09 || l == 0x0A || l == 0x0D { bytes.removeLast() }
        for i in bytes.indices { bytes[i] = fold(bytes[i]) }
        return bytes
    }

    // MARK: 建表

    public init(_ dictionary: MDict) {
        self.dictionary = dictionary
        let d = dictionary
        let n = d.keyCount

        var order = [UInt32](unsafeUninitializedCapacity: n) { buf, count in
            for i in 0..<n { buf[i] = UInt32(i) }
            count = n
        }
        d.keyBlob.withUnsafeBufferPointer { blob in
            let base = blob.baseAddress!
            let starts = d.keyStarts
            order.sort { a, b in
                let (ai, bi) = (Int(a), Int(b))
                let (as_, ae) = (Int(starts[ai]), Int(starts[ai + 1]) - 1)
                let (bs, be) = (Int(starts[bi]), Int(starts[bi + 1]) - 1)
                var i = 0
                while i < min(ae - as_, be - bs) {
                    let x = Self.fold(base[as_ + i]), y = Self.fold(base[bs + i])
                    if x != y { return x < y }
                    i += 1
                }
                if (ae - as_) != (be - bs) { return (ae - as_) < (be - bs) }
                return ai < bi                                  // 归一化后完全相同：保持原始顺序
            }
        }
        self.order = order

        var mixed: [UInt32] = []
        for i in 0..<n where d.keyBytes(at: i).contains(where: { $0 >= 0x41 && $0 <= 0x5A }) {
            mixed.append(UInt32(i))
        }
        self.mixedCase = mixed
    }

    /// 缓存命中的路径：排序结果由调用方提供（来自索引缓存文件），跳过全量排序。
    /// 正确性靠缓存层守（源文件大小 + 修改时间），这里不重验——重验就是重排。
    public init(_ dictionary: MDict, order: [UInt32], mixedCase: [UInt32]) {
        self.dictionary = dictionary
        self.order = order
        self.mixedCase = mixedCase
    }

    // MARK: 查询

    /// 归一化后与 `query` 完全相同的全部条目号，按原始顺序。
    ///
    /// 返回数组而不是单个——「上当」在 OALDPE 里有两条不同的词条，
    /// 只返回第一条会让第二条永远查不到。
    public func exact(_ query: String) -> [Int] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }
        let lower = lowerBound(needle)
        var out: [Int] = []
        var i = lower
        while i < order.count, compare(entry: Int(order[i]), to: needle) == .orderedSame {
            out.append(Int(order[i])); i += 1
        }
        return out.sorted()
    }

    /// 以 `query` 开头的条目号，按归一化顺序，最多 `limit` 条。
    public func prefix(_ query: String, limit: Int = 50) -> [Int] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }
        var out: [Int] = []
        var i = lowerBound(needle)
        while i < order.count, out.count < limit, hasPrefix(entry: Int(order[i]), needle) {
            out.append(Int(order[i])); i += 1
        }
        return out
    }

    /// 词头里**含有** `query` 的条目号，最多 `limit` 条。中→英反查靠这个。
    ///
    /// 对整块 keyBlob 跑 `memmem`——实测 46.4 万词头（5.65 MB）一趟 3 ms。
    /// 逐条 `String.contains` 要 159 ms，差 50 倍，因为那是按字素簇比的。
    public func substring(_ query: String, limit: Int = 50) -> [Int] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return [] }
        let d = dictionary
        var hits: [Int] = []
        var seen = Set<Int>()

        d.keyBlob.withUnsafeBufferPointer { blob in
            guard let origin = blob.baseAddress else { return }
            var cursor = 0
            while cursor + needle.count <= blob.count, hits.count < limit {
                guard let found = memmem(origin + cursor, blob.count - cursor, needle, needle.count) else { break }
                let position = origin.distance(to: found.assumingMemoryBound(to: UInt8.self))
                let entry = entryIndex(containing: position)
                if seen.insert(entry).inserted { hits.append(entry) }
                cursor = position + 1
            }
        }

        // memmem 只认字节，漏掉的是词头里带大写的那一小撮，单独折叠比一遍补上。
        if hits.count < limit {
            for e in mixedCase where !seen.contains(Int(e)) {
                let folded = d.keyBytes(at: Int(e)).map(Self.fold)
                if contains(folded, needle) {
                    hits.append(Int(e)); seen.insert(Int(e))
                    if hits.count >= limit { break }
                }
            }
        }
        return hits
    }

    // MARK: 内部

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var i = 0
            while i < needle.count, haystack[start + i] == needle[i] { i += 1 }
            if i == needle.count { return true }
        }
        return false
    }

    /// keyBlob 里的字节位置 → 条目号。keyStarts 是升序的，二分。
    private func entryIndex(containing position: Int) -> Int {
        let starts = dictionary.keyStarts
        var low = 0, high = starts.count - 2
        while low < high {
            let mid = (low + high + 1) / 2
            if Int(starts[mid]) <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// order 里第一个 ≥ needle 的位置。
    private func lowerBound(_ needle: [UInt8]) -> Int {
        var low = 0, high = order.count
        while low < high {
            let mid = (low + high) / 2
            if compare(entry: Int(order[mid]), to: needle) == .orderedAscending { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func compare(entry: Int, to needle: [UInt8]) -> ComparisonResult {
        let key = dictionary.keyBytes(at: entry)
        var i = key.startIndex, j = 0
        while i < key.endIndex, j < needle.count {
            let x = Self.fold(key[i])
            if x != needle[j] { return x < needle[j] ? .orderedAscending : .orderedDescending }
            i += 1; j += 1
        }
        let remaining = key.endIndex - i
        if remaining == 0 && j == needle.count { return .orderedSame }
        return remaining == 0 ? .orderedAscending : .orderedDescending
    }

    private func hasPrefix(entry: Int, _ needle: [UInt8]) -> Bool {
        let key = dictionary.keyBytes(at: entry)
        guard key.count >= needle.count else { return false }
        var i = key.startIndex
        for byte in needle {
            if Self.fold(key[i]) != byte { return false }
            i += 1
        }
        return true
    }
}
