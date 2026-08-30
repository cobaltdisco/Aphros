import Foundation

/// 一部 MDict 词典（.mdx 正文 或 .mdd 资源）。
///
/// 打开时只读取头部与键索引，**不碰记录数据**——记录按需按块解压。
/// 实测：oaldpe.mdx（46 万词头）建索引 0.4 秒；oaldpe.1.mdd（1.1 GB）峰值内存 90 MB。
///
/// **Sendable 是安全的**：打开之后所有属性都不再变，唯一的可变状态是区块缓存，
/// 它自己带锁。界面层因此可以在后台线程打开词典、在主线程取正文。
public final class MDict: @unchecked Sendable {

    public let url: URL
    public let header: MDictHeader
    public let isResourceFile: Bool

    /// 全部词头的 UTF-8 字节，逐条以 NUL 分隔，连续存放。
    ///
    /// 不用 `[String]` 是因为 46.4 万个 Swift String 在 iPhone 上要 20–30 MB
    /// （实测词头平均 11 字节，短的内联但长短语要上堆），紧凑成一块只要 5.7 MB。
    /// NUL 分隔让子串搜索能直接对整块跑 `memmem`，不必逐条比。
    public private(set) var keyBlob: [UInt8] = []
    /// 第 i 条词头在 `keyBlob` 里的起点，共 `keyCount + 1` 项。
    public private(set) var keyStarts: [UInt32] = []
    /// 第 i 条记录在「所有记录块解压后拼接空间」里的起始偏移。
    public private(set) var recordOffsets: [UInt32] = []

    private let data: Data
    private let numberWidth: Int
    private let textWidth: Int
    private let stringEncoding: String.Encoding

    /// 记录段：每块的压缩数据在文件里的位置，以及它在「拼接空间」里覆盖的区间。
    private struct RecordBlock {
        let fileOffset: Int
        let compressedSize: Int
        /// 在拼接空间里的起点，`decompressedStart ..< decompressedStart + decompressedSize`。
        let decompressedStart: Int
        let decompressedSize: Int
    }
    private var recordBlocks: [RecordBlock] = []
    private var totalRecordSize = 0
    private let cache: BlockCache

    /// 记录索引在文件里的起始偏移（键区块之后）。索引缓存要记下它：
    /// 缓存命中的打开路径跳过整个键索引解析，直接从这里读记录索引。
    public private(set) var recordIndexOffset = 0

    /// - Parameter cacheCapacity: 解压后区块缓存的字节上限。默认 8 MB——mdx 区块约 64 KB，
    ///   够放百来块；正文页面通常在相邻块里，命中率高。iPhone 上三部词典同时开也只有 24 MB。
    public init(contentsOf url: URL, cacheCapacity: Int = 8 << 20) throws {
        self.url = url
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.header = try MDictHeader.read(from: data)
        self.isResourceFile = url.pathExtension.lowercased() == "mdd"
        self.cache = BlockCache(capacity: cacheCapacity)

        guard header.engineVersion >= 1.2 else {
            throw MDictError.unsupportedEngineVersion(String(header.engineVersion))
        }
        self.numberWidth = header.engineVersion >= 2.0 ? 8 : 4
        // .mdd 的键一律 UTF-16LE，无视头部声明的 Encoding。
        self.textWidth = isResourceFile ? 2 : 1
        self.stringEncoding = isResourceFile ? .utf16LittleEndian
            : (header.encoding.replacingOccurrences(of: "-", with: "") == "GBK" ? .init(rawValue: 0x80000632) : .utf8)

        var reader = ByteReader(data, at: header.bodyOffset)
        try readKeyIndex(from: &reader)
        recordIndexOffset = reader.offset
        try readRecordIndex(from: &reader)
    }

    /// 缓存命中的打开路径：键索引三个数组由调用方提供（来自索引缓存文件），
    /// 跳过整个键区块解压与解析，只读头部和记录索引（后者毫秒级）。
    ///
    /// **数组必须来自同一个文件的同一版本**——`recordIndexOffset` 是文件内偏移，
    /// 文件换了就是在错误的位置读记录索引。缓存层用源文件的大小 + 修改时间守这一点。
    /// 记录索引自己的守卫照常跑：条目数对不上键数、偏移越界、单调性坏了都会抛，
    /// 所以喂错缓存的失败模式是**报错**而不是静默错数据。
    public init(contentsOf url: URL, cacheCapacity: Int = 8 << 20,
                keyBlob: [UInt8], keyStarts: [UInt32], recordOffsets: [UInt32],
                recordIndexOffset: Int) throws {
        self.url = url
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.header = try MDictHeader.read(from: data)
        self.isResourceFile = url.pathExtension.lowercased() == "mdd"
        self.cache = BlockCache(capacity: cacheCapacity)

        guard header.engineVersion >= 1.2 else {
            throw MDictError.unsupportedEngineVersion(String(header.engineVersion))
        }
        self.numberWidth = header.engineVersion >= 2.0 ? 8 : 4
        self.textWidth = isResourceFile ? 2 : 1
        self.stringEncoding = isResourceFile ? .utf16LittleEndian
            : (header.encoding.replacingOccurrences(of: "-", with: "") == "GBK" ? .init(rawValue: 0x80000632) : .utf8)

        self.keyBlob = keyBlob
        self.keyStarts = keyStarts
        self.recordOffsets = recordOffsets
        self.recordIndexOffset = recordIndexOffset
        var reader = ByteReader(data, at: recordIndexOffset)
        try readRecordIndex(from: &reader)
    }

    public var keyCount: Int { recordOffsets.count }

    /// 第 i 条词头的原始字节（不分配，不解码）。比较和搜索都走这条。
    public func keyBytes(at index: Int) -> ArraySlice<UInt8> {
        keyBlob[Int(keyStarts[index])..<(Int(keyStarts[index + 1]) - 1)]   // −1 跳过分隔用的 NUL
    }

    /// 第 i 条词头。只在要显示时才调用——每次调用都会新建一个 String。
    public func key(at index: Int) -> String {
        String(decoding: keyBytes(at: index), as: UTF8.self)
    }

    /// 全部词头的只读视图。方便测试和遍历，**逐条构造 String**，不要在热路径上用。
    public struct Keys: RandomAccessCollection {
        let dict: MDict
        public var startIndex: Int { 0 }
        public var endIndex: Int { dict.keyCount }
        public subscript(i: Int) -> String { dict.key(at: i) }
    }
    public var keys: Keys { Keys(dict: self) }

    /// 记录块解压后的总字节数。等于所有词条正文（含分隔用的 NUL）拼起来的长度。
    public var recordSectionSize: Int { totalRecordSize }

    /// 记录块数量。诊断用。
    public var recordBlockCount: Int { recordBlocks.count }

    // MARK: 键索引

    private func readKeyIndex(from reader: inout ByteReader) throws {
        let v2 = header.engineVersion >= 2.0

        let blockCount = try reader.number(width: numberWidth)
        _ = try reader.number(width: numberWidth)                 // 声明的条目总数
        let infoDecompressedSize = v2 ? try reader.number(width: numberWidth) : 0
        let infoSize  = try reader.number(width: numberWidth)
        _ = try reader.number(width: numberWidth)                 // 键区块总字节数
        if v2 { try reader.skip(4) }                              // 上面这段的 adler32

        var info = try reader.bytes(infoSize)
        if v2 {
            if header.keyIndexIsEncrypted { info = Self.decryptKeyIndex(info) }
            info = try Decompress.block(info, expectedSize: infoDecompressedSize)
        }

        let blocks = try parseKeyBlockInfo(info, blockCount: blockCount)
        try readKeyBlocks(blocks, from: &reader)
    }

    private struct KeyBlockInfo { let compressedSize: Int; let decompressedSize: Int }

    private func parseKeyBlockInfo(_ info: Data, blockCount: Int) throws -> [KeyBlockInfo] {
        var reader = ByteReader(info)
        let v2 = header.engineVersion >= 2.0
        let terminator = v2 ? 1 : 0          // v2 的首/末键带一个 NUL 结尾
        var out: [KeyBlockInfo] = []
        out.reserveCapacity(blockCount)

        for _ in 0..<blockCount {
            try reader.skip(numberWidth)                          // 本块条目数
            for _ in 0..<2 {                                      // 首键、末键，只需跳过
                let len = v2 ? Int(try reader.u16()) : Int(try reader.u8())
                try reader.skip((len + terminator) * textWidth)
            }
            out.append(KeyBlockInfo(compressedSize: try reader.number(width: numberWidth),
                                    decompressedSize: try reader.number(width: numberWidth)))
        }
        return out
    }

    private func readKeyBlocks(_ blocks: [KeyBlockInfo], from reader: inout ByteReader) throws {
        let estimate = blocks.reduce(0) { $0 + $1.decompressedSize / 24 }
        keyBlob.reserveCapacity(blocks.reduce(0) { $0 + $1.decompressedSize })
        keyStarts.reserveCapacity(estimate + 1)
        recordOffsets.reserveCapacity(estimate)
        let delimiterWidth = textWidth

        for (i, block) in blocks.enumerated() {
            let raw = try reader.bytes(block.compressedSize)
            let plain = try Decompress.block(raw, expectedSize: block.decompressedSize, index: i)

            var cursor = 0
            plain.withUnsafeBytes { buf in
                let base = buf.bindMemory(to: UInt8.self)
                while cursor + numberWidth < plain.count {
                    var offset = 0
                    for b in 0..<numberWidth { offset = (offset << 8) | Int(base[cursor + b]) }
                    cursor += numberWidth

                    var end = cursor
                    while end + delimiterWidth <= plain.count {
                        if delimiterWidth == 1 {
                            if base[end] == 0 { break }
                        } else if base[end] == 0 && base[end + 1] == 0 { break }
                        end += delimiterWidth
                    }
                    keyStarts.append(UInt32(keyBlob.count))
                    if needsTranscoding {
                        // GBK 或 .mdd 的 UTF-16LE：先解码再转成 UTF-8 存。
                        let raw = Data(bytes: base.baseAddress! + cursor, count: end - cursor)
                        keyBlob.append(contentsOf: (String(data: raw, encoding: stringEncoding) ?? "").utf8)
                    } else {
                        keyBlob.append(contentsOf: UnsafeBufferPointer(start: base.baseAddress! + cursor,
                                                                      count: end - cursor))
                    }
                    keyBlob.append(0)
                    recordOffsets.append(UInt32(offset))
                    cursor = end + delimiterWidth
                }
            }
        }
        keyStarts.append(UInt32(keyBlob.count))
    }

    /// UTF-8 的 mdx 可以把键字节原样搬进 keyBlob；GBK 和 .mdd 的 UTF-16LE 得先转码。
    private var needsTranscoding: Bool { stringEncoding != .utf8 }

    // MARK: 记录索引

    /// 记录段紧跟在键区块之后，布局是四个整数（块数 / 条目数 / 信息表字节数 / 压缩数据总字节数），
    /// 然后是块数对 `(压缩后长度, 解压后长度)`，最后才是各记录块本身。
    /// **注意：这张信息表既不压缩也不加密**，和键区块信息表不同。
    private func readRecordIndex(from reader: inout ByteReader) throws {
        let blockCount = try reader.number(width: numberWidth)
        let declaredEntries = try reader.number(width: numberWidth)
        let infoSize = try reader.number(width: numberWidth)
        let declaredCompressed = try reader.number(width: numberWidth)

        guard infoSize == blockCount * numberWidth * 2 else {
            throw MDictError.recordIndexMalformed(
                reason: "信息表 \(infoSize) 字节，按 \(blockCount) 块算应为 \(blockCount * numberWidth * 2)")
        }
        // 键索引给出的条目数应当和记录段声明的一致。不一致说明前面某处解析已经错位了，
        // 此时继续往下读只会静默返回错数据——ADR 0002 记的就是这种失败模式。
        guard declaredEntries == keyCount else {
            throw MDictError.recordCountMismatch(declared: declaredEntries, got: keyCount)
        }

        recordBlocks.reserveCapacity(blockCount)
        var sizes: [(Int, Int)] = []
        sizes.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            let compressed = try reader.number(width: numberWidth)
            let decompressed = try reader.number(width: numberWidth)
            sizes.append((compressed, decompressed))
        }

        // 累计表必须用**解压后**长度建。混用压缩长度会整块错位，返回的是相邻词条的
        // 合法 HTML——不崩、不抛、看着正常。这里顺手核一遍压缩长度的总和，
        // 对不上说明信息表本身读错了。
        guard sizes.reduce(0, { $0 + $1.0 }) == declaredCompressed else {
            throw MDictError.recordIndexMalformed(
                reason: "压缩长度累加 \(sizes.reduce(0, { $0 + $1.0})) ≠ 声明的 \(declaredCompressed)")
        }

        var fileOffset = reader.offset
        var decompressedStart = 0
        for (compressed, decompressed) in sizes {
            recordBlocks.append(RecordBlock(fileOffset: fileOffset,
                                            compressedSize: compressed,
                                            decompressedStart: decompressedStart,
                                            decompressedSize: decompressed))
            fileOffset += compressed
            decompressedStart += decompressed
        }
        totalRecordSize = decompressedStart

        guard fileOffset <= data.count else { throw MDictError.truncated(at: data.count) }

        // 单条记录的终点靠**下一条的起点**确定，前提是偏移单调不减。这一点没有任何格式
        // 文档保证，所以在这里查一次——错了要炸，不能悄悄切出半条正文。
        for i in 1..<max(keyCount, 1) where recordOffsets[i] < recordOffsets[i - 1] {
            throw MDictError.recordOffsetsNotMonotonic(at: i)
        }
        if let last = recordOffsets.last, Int(last) > totalRecordSize {
            throw MDictError.recordOffsetOutOfRange(offset: Int(last), total: totalRecordSize)
        }
    }

    // MARK: 取记录

    /// 第 `index` 条记录的原始字节。mdx 是 HTML 正文，mdd 是资源文件内容。
    public func recordData(at index: Int) throws -> Data {
        guard recordOffsets.indices.contains(index) else {
            throw MDictError.recordOffsetOutOfRange(offset: index, total: keyCount)
        }
        let start = Int(recordOffsets[index])
        // 终点是**下一个不同的**起点。三部词典实测相邻同偏移为 0 条，但别名（多个词头
        // 指向同一条记录）在格式上完全合法，撞上时 start == end 会返回空正文——
        // 一个不抛错的空白页比抛错难查得多。
        var next = index + 1
        while next < keyCount, Int(recordOffsets[next]) == start { next += 1 }
        let end = next < keyCount ? Int(recordOffsets[next]) : totalRecordSize
        guard start <= end, end <= totalRecordSize else {
            throw MDictError.recordOffsetOutOfRange(offset: end, total: totalRecordSize)
        }
        return try bytes(in: start..<end)
    }

    /// 第 `index` 条记录解成文本。**只对 .mdx 有意义**。
    ///
    /// 记录之间用 NUL 分隔，切出来的片段尾部带 NUL，要剥掉——不剥的话
    /// 字节数会比参考实现多 1，golden test 立刻能看出来。
    public func recordText(at index: Int) throws -> String {
        var raw = try recordData(at: index)
        while raw.last == 0 { raw.removeLast() }
        guard let text = String(data: raw, encoding: stringEncoding) else {
            throw MDictError.recordNotDecodable(index: index)
        }
        return text
    }

    /// 从「拼接空间」里切出一段。记录**可能跨块**——格式不保证一条记录落在单块内，
    /// 所以这里按块循环拼接，而不是假设一次就够。
    private func bytes(in range: Range<Int>) throws -> Data {
        guard !range.isEmpty else { return Data() }
        var out = Data(capacity: range.count)
        var cursor = range.lowerBound
        var blockIndex = try blockIndex(containing: cursor)

        while cursor < range.upperBound {
            guard recordBlocks.indices.contains(blockIndex) else {
                throw MDictError.recordOffsetOutOfRange(offset: cursor, total: totalRecordSize)
            }
            let block = recordBlocks[blockIndex]
            let plain = try decompressedBlock(blockIndex)
            let localStart = cursor - block.decompressedStart
            let localEnd = min(range.upperBound - block.decompressedStart, plain.count)
            guard localStart >= 0, localStart <= localEnd else {
                throw MDictError.recordOffsetOutOfRange(offset: cursor, total: totalRecordSize)
            }
            out.append(plain.subdata(in: (plain.startIndex + localStart)..<(plain.startIndex + localEnd)))
            cursor = block.decompressedStart + localEnd
            blockIndex += 1
        }
        return out
    }

    /// 二分找出偏移落在哪一块。46 万条记录分散在几千个块里，线性找会拖慢每一次查词。
    private func blockIndex(containing offset: Int) throws -> Int {
        var low = 0, high = recordBlocks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let block = recordBlocks[mid]
            if offset < block.decompressedStart { high = mid - 1 }
            else if offset >= block.decompressedStart + block.decompressedSize { low = mid + 1 }
            else { return mid }
        }
        throw MDictError.recordOffsetOutOfRange(offset: offset, total: totalRecordSize)
    }

    private func decompressedBlock(_ index: Int) throws -> Data {
        if let hit = cache.value(for: index) { return hit }
        let block = recordBlocks[index]
        guard block.fileOffset + block.compressedSize <= data.count else {
            throw MDictError.truncated(at: block.fileOffset)
        }
        // 记录块加密（bit0）是真 DRM，需要注册码。到这一步才报，是因为键索引本身能读，
        // 只有取正文时才会撞上。
        guard !header.recordsAreEncrypted else { throw MDictError.recordEncrypted }

        var reader = ByteReader(data, at: block.fileOffset)
        let raw = try reader.bytes(block.compressedSize)
        let plain = try Decompress.block(raw, expectedSize: block.decompressedSize, index: index)
        cache.insert(plain, for: index)
        return plain
    }

    /// 清空区块缓存。收到内存警告时调用。
    public func purgeCache() { cache.removeAll() }

    /// `Encrypted="2"` 的键区块信息解密。
    ///
    /// 密钥 = ripemd128(info[4..<8] ‖ 0x95 0x36 0x00 0x00)，其中 info[4..<8] 是这段数据自己的
    /// adler32。**输入的每一个比特都来自文件本身——`RegisterBy="EMail"` 从头到尾没被读过**，
    /// 所以不需要任何注册码。前 8 字节是明文，从第 8 字节起做逐字节流解密。
    static func decryptKeyIndex(_ info: Data) -> Data {
        var seed = info.subdata(in: (info.startIndex + 4)..<(info.startIndex + 8))
        seed.append(contentsOf: [0x95, 0x36, 0x00, 0x00])
        let key = [UInt8](RIPEMD128.hash(seed))

        var out = [UInt8](info)
        var previous: UInt8 = 0x36
        for i in 8..<out.count {
            let byte = out[i]
            var t = (byte >> 4) | (byte << 4)
            t ^= previous
            t ^= UInt8(truncatingIfNeeded: i - 8)
            t ^= key[(i - 8) % key.count]
            previous = byte
            out[i] = t
        }
        return Data(out)
    }
}
