import Foundation

/// mdx/mdd 文件开头的 XML 头部。
public struct MDictHeader: Sendable {
    public let attributes: [String: String]
    /// 头部之后第一个字节的偏移（键区块头从这里开始）。
    public let bodyOffset: Int

    /// **属性名大小写不敏感**——OALDPE 写 `StripKey`，cecd2024 写 `Stripkey`，实测两种都存在。
    public subscript(_ name: String) -> String? {
        let lowered = name.lowercased()
        return attributes.first { $0.key.lowercased() == lowered }?.value
    }

    public var engineVersion: Double { Double(self["GeneratedByEngineVersion"] ?? "1.2") ?? 1.2 }
    public var title: String? { self["Title"] }
    public var encoding: String { (self["Encoding"] ?? "UTF-8").uppercased() }
    public var isKeyCaseSensitive: Bool { self["KeyCaseSensitive"]?.lowercased() == "yes" }
    public var stripsKey: Bool { self["StripKey"]?.lowercased() == "yes" }

    /// `Encrypted` 是位掩码，但值可能是 `No` / `Yes` / `0` / `1` / `2`，直接 Int() 会抛。
    /// bit0 = 记录块加密（真 DRM，需注册码）；bit1 = 键区块信息加密（ripemd128 派生，可解）。
    public var encryptionFlags: Int {
        switch (self["Encrypted"] ?? "0").lowercased() {
        case "no", "": 0
        case "yes":    2
        case let s:    Int(s) ?? 0
        }
    }
    public var recordsAreEncrypted: Bool { encryptionFlags & 0x01 != 0 }
    public var keyIndexIsEncrypted: Bool { encryptionFlags & 0x02 != 0 }

    static func read(from data: Data) throws -> MDictHeader {
        guard data.count >= 8 else { throw MDictError.fileTooSmall(expected: 8, got: data.count) }
        var reader = ByteReader(data)
        let length = Int(try reader.u32())
        let raw = try reader.bytes(length)
        let declared = try reader.u32()

        // 头部的 adler32 是小端存的（与区块不同），这是格式本身的不一致，不是笔误。
        let actual = Adler32.checksum(raw).byteSwapped
        guard actual == declared else {
            throw MDictError.headerChecksumMismatch(expected: declared, got: actual)
        }
        guard let text = String(data: raw, encoding: .utf16LittleEndian) else {
            throw MDictError.headerNotUTF16
        }
        return MDictHeader(attributes: parseAttributes(text), bodyOffset: reader.offset)
    }

    static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        let pattern = /(\w+)="([^"]*)"/
        for m in text.matches(of: pattern) {
            out[String(m.1)] = String(m.2)
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return out
    }
}
