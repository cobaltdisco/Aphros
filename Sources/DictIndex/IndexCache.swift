import Foundation
import MDictKit

/// 词头索引的磁盘缓存。
///
/// ADR 0008 当时定的：真要落盘，格式就是把 `keyBlob / keyStarts / recordOffsets /
/// order`（外加 `mixedCase` 和记录索引偏移）直接写文件，**不是 SQLite**。
/// 2026-08-25 用户拍板落地。冷启动从「解压键区块 + 排序 46 万词头」变成
/// 「读一个 ~11 MB 文件 + 记录索引」。
///
/// **失效靠源文件指纹（字节数 + 修改时间），全自动**：换了词典文件，指纹对不上，
/// 下一次启动自动重建并重写缓存——用户永远不需要手动清什么。指纹守的是
/// `recordIndexOffset` 这类文件内偏移的有效性；万一指纹撞了（同大小同 mtime 的
/// 不同文件，几乎不可能），MDict 记录索引自己的守卫（条目数、单调性、越界）
/// 会把它变成**报错**而不是静默错数据。
///
/// 布局（全部小端，Int 一律写 u64）：
///
///     magic "DIDX" · version u32 · sourceSize u64 · sourceMTimeNs u64
///     recordIndexOffset u64 · keyBlobCount u64 · keyStartsCount u64
///     recordOffsetsCount u64 · orderCount u64 · mixedCaseCount u64
///     keyBlob [u8] · keyStarts [u32] · recordOffsets [u32] · order [u32] · mixedCase [u32]
public enum IndexCache {

    static let magic: UInt32 = 0x58444944          // "DIDX" 小端
    /// 布局或**语义**变了就升版本：归一化规则（fold / normalize）一变，
    /// order 就作废，但源文件指纹看不出来——只能靠这个数字把旧缓存全部打掉。
    static let version: UInt32 = 1

    // MARK: 指纹

    private static func fingerprint(of url: URL) -> (size: UInt64, mtimeNs: UInt64)? {
        // path(percentEncoded: false)：默认的 path() 带百分号转义，
        // 「Oxford Advanced」里的空格会变成 %20，attributesOfItem 直接找不到文件。
        guard let attrs = try? FileManager.default
                .attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? UInt64,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (size, UInt64(mtime.timeIntervalSince1970 * 1_000_000_000))
    }

    // MARK: 写

    /// 写出 `table` 的全部索引数据。原子写：中途断电留下的是旧文件或没有文件，
    /// 不会是半个文件。
    public static func write(_ table: KeyTable, source: URL, to cacheURL: URL) throws {
        guard let fp = fingerprint(of: source) else { return }
        let d = table.dictionary

        var out = Data(capacity: 72 + d.keyBlob.count
                       + (d.keyStarts.count + d.recordOffsets.count
                          + table.order.count + table.mixedCase.count) * 4)
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func put(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(magic); put(version)
        put(fp.size); put(fp.mtimeNs)
        put(UInt64(d.recordIndexOffset))
        put(UInt64(d.keyBlob.count)); put(UInt64(d.keyStarts.count))
        put(UInt64(d.recordOffsets.count)); put(UInt64(table.order.count))
        put(UInt64(table.mixedCase.count))
        out.append(contentsOf: d.keyBlob)
        for array in [d.keyStarts, d.recordOffsets, table.order, table.mixedCase] {
            array.withUnsafeBufferPointer { out.append(Data(buffer: $0)) }
        }

        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: cacheURL, options: .atomic)
    }

    // MARK: 读

    /// 命中返回完整的查询表；缓存不存在、版本不对、指纹不符、长度不对都返回 nil
    /// ——调用方走全量重建。这里**任何**异常都不该让 App 打不开词典。
    public static func load(source: URL, from cacheURL: URL) -> KeyTable? {
        guard let fp = fingerprint(of: source),
              let blob = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              blob.count >= 72 else { return nil }

        var cursor = blob.startIndex
        func u32() -> UInt32 {
            let v = blob[cursor..<(cursor + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            cursor += 4
            return UInt32(littleEndian: v)
        }
        func u64() -> UInt64 {
            let v = blob[cursor..<(cursor + 8)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            cursor += 8
            return UInt64(littleEndian: v)
        }
        guard u32() == magic, u32() == version,
              u64() == fp.size, u64() == fp.mtimeNs else { return nil }
        let recordIndexOffset = Int(u64())
        let counts = (blob: Int(u64()), starts: Int(u64()),
                      records: Int(u64()), order: Int(u64()), mixed: Int(u64()))
        let payload = counts.blob + (counts.starts + counts.records + counts.order + counts.mixed) * 4
        guard blob.count == 72 + payload,
              counts.starts == counts.records + 1, counts.order == counts.records else { return nil }

        func bytes(_ n: Int) -> [UInt8] {
            defer { cursor += n }
            return [UInt8](blob[cursor..<(cursor + n)])
        }
        func u32s(_ n: Int) -> [UInt32] {
            defer { cursor += n * 4 }
            return blob[cursor..<(cursor + n * 4)].withUnsafeBytes { raw in
                [UInt32](unsafeUninitializedCapacity: n) { dst, count in
                    raw.copyBytes(to: UnsafeMutableRawBufferPointer(dst))
                    count = n
                }
            }
        }
        let keyBlob = bytes(counts.blob)
        let keyStarts = u32s(counts.starts)
        let recordOffsets = u32s(counts.records)
        let order = u32s(counts.order)
        let mixedCase = u32s(counts.mixed)

        guard let dictionary = try? MDict(contentsOf: source,
                                          keyBlob: keyBlob, keyStarts: keyStarts,
                                          recordOffsets: recordOffsets,
                                          recordIndexOffset: recordIndexOffset)
        else { return nil }
        return KeyTable(dictionary, order: order, mixedCase: mixedCase)
    }
}
