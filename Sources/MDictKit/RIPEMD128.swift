import Foundation

/// RIPEMD-128。CryptoKit 没有，而 MDict 的 `Encrypted="2"` 用它派生键区块信息的解密密钥。
/// 参考：Dobbertin / Bosselaers / Preneel, "RIPEMD-160: A Strengthened Version of RIPEMD" (1996)
public enum RIPEMD128 {

    public static func hash(_ message: Data) -> Data {
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]

        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in 0..<8 { msg.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }   // 小端

        msg.withUnsafeBytes { raw in
            for blockStart in stride(from: 0, to: raw.count, by: 64) {
                var x = [UInt32](repeating: 0, count: 16)
                for i in 0..<16 {
                    let o = blockStart + i * 4
                    x[i] = UInt32(raw[o]) | UInt32(raw[o + 1]) << 8
                         | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24   // 小端
                }
                var (a, b, c, d)     = (h[0], h[1], h[2], h[3])
                var (aa, bb, cc, dd) = (h[0], h[1], h[2], h[3])

                for j in 0..<64 {
                    let round = j >> 4
                    let t1 = rol(a &+ f(j, b, c, d) &+ x[Int(r[j])] &+ k[round], s[j])
                    (a, d, c, b) = (d, c, b, t1)
                    let t2 = rol(aa &+ f(63 - j, bb, cc, dd) &+ x[Int(rp[j])] &+ kp[round], sp[j])
                    (aa, dd, cc, bb) = (dd, cc, bb, t2)
                }

                let t = h[1] &+ c &+ dd
                h[1] = h[2] &+ d &+ aa
                h[2] = h[3] &+ a &+ bb
                h[3] = h[0] &+ b &+ cc
                h[0] = t
            }
        }

        var out = Data(capacity: 16)
        for word in h { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> (8 * UInt32(i)))) } }
        return out
    }

    // MARK: 轮函数与常量

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case ..<16: x ^ y ^ z
        case ..<32: (x & y) | (~x & z)
        case ..<48: (x | ~y) ^ z
        default:    (x & z) | (y & ~z)
        }
    }

    private static func rol(_ x: UInt32, _ n: UInt8) -> UInt32 {
        (x << UInt32(n)) | (x >> (32 - UInt32(n)))
    }

    private static let k:  [UInt32] = [0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc]
    private static let kp: [UInt32] = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x00000000]

    private static let r: [UInt8] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
        7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
        3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12,
        1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2]
    private static let rp: [UInt8] = [
        5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12,
        6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
        15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13,
        8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14]
    private static let s: [UInt8] = [
        11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8,
        7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
        11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5,
        11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12]
    private static let sp: [UInt8] = [
        8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6,
        9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
        9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5,
        15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8]
}
