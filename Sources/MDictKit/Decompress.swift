import Compression
import Foundation

enum Decompress {

    /// MDict 的每个区块前 8 字节是：4 字节压缩类型 + 4 字节 adler32（大端，针对解压后的数据）。
    /// 类型 0 = 不压缩，1 = LZO，2 = zlib。本项目的三部词典实测 100% 是 zlib。
    static func block(_ raw: Data, expectedSize: Int? = nil, index: Int = 0,
                      verifyChecksum: Bool = true) throws -> Data {
        guard raw.count >= 8 else { throw MDictError.truncated(at: 0) }
        let kind = raw[relative: 0]
        var reader = ByteReader(raw, at: 4)
        let expectedAdler = try reader.u32()
        let payload = raw.subdata(in: (raw.startIndex + 8)..<raw.endIndex)

        let out: Data
        switch kind {
        case 0: out = payload
        case 1: throw MDictError.lzoNotSupported
        case 2: out = try inflate(payload, hint: expectedSize)
        default: throw MDictError.unsupportedCompression(kind)
        }

        if verifyChecksum {
            let actual = Adler32.checksum(out)
            guard actual == expectedAdler else {
                throw MDictError.blockChecksumMismatch(index: index, expected: expectedAdler, got: actual)
            }
        }
        if let expectedSize, out.count != expectedSize {
            throw MDictError.keyBlockSizeMismatch(expected: expectedSize, got: out.count)
        }
        return out
    }

    /// zlib 包装流（0x78 …）。Apple 的 COMPRESSION_ZLIB 是**裸 DEFLATE**，
    /// 所以要剥掉 2 字节 zlib 头和 4 字节 adler32 尾。
    static func inflate(_ zlibStream: Data, hint: Int?) throws -> Data {
        guard zlibStream.count > 6 else { throw MDictError.truncated(at: 0) }
        let deflate = zlibStream.subdata(in: (zlibStream.startIndex + 2)..<(zlibStream.endIndex - 4))

        func attempt(_ capacity: Int) -> Data? {
            var out = Data(count: capacity)
            let produced: Int = out.withUnsafeMutableBytes { dst in
                deflate.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        src.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard produced > 0 else { return nil }
            out.count = produced
            return out
        }

        // 区块场景下 hint 一定有（键区块信息和每个区块都带解压后长度），一次成。
        if let hint, let out = attempt(hint) { return out }

        var capacity = max(deflate.count * 4, 64 * 1024)
        for _ in 0..<8 {
            if let out = attempt(capacity), out.count < capacity { return out }
            capacity *= 2
        }
        throw MDictError.truncated(at: 0)
    }
}

enum Adler32 {
    static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                a = (a &+ UInt32(byte)) % 65521
                b = (b &+ a) % 65521
            }
        }
        return (b << 16) | a
    }
}
