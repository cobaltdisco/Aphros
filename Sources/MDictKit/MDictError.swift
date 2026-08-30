import Foundation

public enum MDictError: Error, Equatable, Sendable {
    case fileTooSmall(expected: Int, got: Int)
    case headerChecksumMismatch(expected: UInt32, got: UInt32)
    case headerNotUTF16
    case unsupportedEngineVersion(String)
    case unsupportedCompression(UInt8)
    case blockChecksumMismatch(index: Int, expected: UInt32, got: UInt32)
    case keyBlockSizeMismatch(expected: Int, got: Int)
    case lzoNotSupported
    case recordEncrypted
    case truncated(at: Int)
    // ── 记录段 ──
    case recordIndexMalformed(reason: String)
    case recordCountMismatch(declared: Int, got: Int)
    case recordOffsetsNotMonotonic(at: Int)
    case recordOffsetOutOfRange(offset: Int, total: Int)
    case recordNotDecodable(index: Int)
}

extension MDictError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileTooSmall(let e, let g):        "文件过小：期望至少 \(e) 字节，实际 \(g)"
        case .headerChecksumMismatch(let e, let g): "头部 adler32 校验失败：期望 \(e)，实际 \(g)"
        case .headerNotUTF16:                    "头部不是合法的 UTF-16LE"
        case .unsupportedEngineVersion(let v):   "不支持的 EngineVersion：\(v)"
        case .unsupportedCompression(let t):     "不支持的压缩类型：\(t)"
        case .blockChecksumMismatch(let i, _, _): "第 \(i) 块 adler32 校验失败"
        case .keyBlockSizeMismatch(let e, let g): "键区块解压后长度不符：期望 \(e)，实际 \(g)"
        case .lzoNotSupported:                   "该词典使用 LZO 压缩，本实现只支持 zlib 与不压缩"
        case .recordEncrypted:                   "记录块已加密（Encrypted 含 bit0），需要注册码"
        case .truncated(let at):                 "文件在偏移 \(at) 处意外结束"
        case .recordIndexMalformed(let why):     "记录段信息表异常：\(why)"
        case .recordCountMismatch(let d, let g): "记录条目数不符：记录段声明 \(d)，键索引读出 \(g)"
        case .recordOffsetsNotMonotonic(let i):  "第 \(i) 条记录的偏移小于前一条——无法据此确定记录边界"
        case .recordOffsetOutOfRange(let o, let t): "记录偏移 \(o) 超出范围（总长 \(t)）"
        case .recordNotDecodable(let i):         "第 \(i) 条记录无法按词典声明的编码解码"
        }
    }
}
