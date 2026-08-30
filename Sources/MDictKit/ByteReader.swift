import Foundation

/// 只读的大端字节游标。MDict 的所有整数都是大端。
struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw MDictError.truncated(at: offset) }
        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    mutating func u8()  throws -> UInt8  { try bytes(1)[relative: 0] }
    mutating func u16() throws -> UInt16 { UInt16(try beValue(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try beValue(4)) }
    mutating func u64() throws -> UInt64 { try beValue(8) }

    /// MDict v2 用 8 字节整数，v1.2 用 4 字节。
    mutating func number(width: Int) throws -> Int { Int(try beValue(width)) }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw MDictError.truncated(at: offset) }
        offset += count
    }

    /// MDict 的所有多字节整数都是大端，最宽 8 字节。
    private mutating func beValue(_ width: Int) throws -> UInt64 {
        precondition(width >= 1 && width <= 8)
        let d = try bytes(width)
        var v: UInt64 = 0
        for b in d { v = (v << 8) | UInt64(b) }
        return v
    }
}

extension Data {
    subscript(relative i: Int) -> UInt8 { self[startIndex + i] }
}
