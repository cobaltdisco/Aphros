import Foundation
import Testing
@testable import MDictKit

/// 这些期望值由参考实现在真实词典上实测生成（Tests/MDictKitTests/Fixtures/goldens.json）。
/// 词典本身不在版本库里——3.3 GB，见 .gitignore。所以本地没有 dicts/ 时测试自动跳过。
struct GoldenTests {

    static let repoRoot: URL = {
        var url = URL(filePath: #filePath)          // …/Tests/MDictKitTests/GoldenTests.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    struct Goldens: Decodable {
        struct Record: Decodable {
            let key: String, index: Int, utf8ByteCount: Int, sha256: String
            let isRedirect: Bool, redirectTarget: String?
        }
        struct Dictionary: Decodable {
            let id: String, path: String, encrypted: String, engineVersion: String
            let keyCount: Int, firstKey: String, lastKey: String
            let records: [Record]
        }
        let dictionaries: [Dictionary]
    }

    static let goldens: Goldens = {
        let url = Bundle.module.url(forResource: "goldens", withExtension: "json")!
        return try! JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
    }()

    // MARK: 不依赖词典文件的测试

    @Test("RIPEMD-128 通过 RFC 测试向量")
    func ripemd128Vectors() {
        func hex(_ s: String) -> String {
            RIPEMD128.hash(Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        #expect(hex("")               == "cdf26213a150dc3ecb610f18f6b38b46")
        #expect(hex("a")              == "86be7afa339d0fc7cfc785e72f578d33")
        #expect(hex("abc")            == "c14a12199c66e4ba84636b0f69144c77")
        #expect(hex("message digest") == "9e327b3d6e523062afc1132d7df9d1b8")
        #expect(hex("abcdefghijklmnopqrstuvwxyz") == "fd2aa607f71dc8f510714922b371834e")
    }

    @Test("Adler-32 与 zlib 一致")
    func adler32() {
        #expect(Adler32.checksum(Data())              == 1)
        #expect(Adler32.checksum(Data("abc".utf8))    == 0x024d0127)
        #expect(Adler32.checksum(Data("Wikipedia".utf8)) == 0x11e60398)
    }

    @Test("Encrypted 属性的各种写法都能解析")
    func encryptionFlagParsing() {
        func flags(_ raw: String) -> Int {
            MDictHeader(attributes: ["Encrypted": raw], bodyOffset: 0).encryptionFlags
        }
        #expect(flags("No")  == 0)      // cecd2024
        #expect(flags("2")   == 2)      // oaldpe / oxfordadvanced
        #expect(flags("Yes") == 2)
        #expect(flags("0")   == 0)
        #expect(flags("3")   == 3)
        #expect(MDictHeader(attributes: ["Encrypted": "2"], bodyOffset: 0).recordsAreEncrypted == false)
        #expect(MDictHeader(attributes: ["Encrypted": "2"], bodyOffset: 0).keyIndexIsEncrypted == true)
    }

    @Test("头部属性名大小写不敏感")
    func headerIsCaseInsensitive() {
        // OALDPE 写 StripKey，cecd2024 写 Stripkey —— 实测两种都存在。
        let a = MDictHeader(attributes: ["StripKey": "No"],  bodyOffset: 0)
        let b = MDictHeader(attributes: ["Stripkey": "Yes"], bodyOffset: 0)
        #expect(a["stripkey"] == "No")
        #expect(b.stripsKey == true)
    }

    // MARK: 依赖真实词典的测试（本地没有 dicts/ 时跳过）

    @Test("词典能打开，键索引与实测值一致", arguments: goldens.dictionaries)
    func keyIndexMatchesGolden(_ spec: Goldens.Dictionary) throws {
        let url = Self.repoRoot.appending(path: spec.path)
        try withKnownIssue("本地没有 \(spec.path)，跳过", isIntermittent: true) {
            guard FileManager.default.fileExists(atPath: url.path) else { throw SkipDictionary() }
            let dict = try MDict(contentsOf: url)
            #expect(dict.header["Encrypted"] == spec.encrypted)
            #expect(dict.header["GeneratedByEngineVersion"] == spec.engineVersion)
            #expect(dict.keyCount == spec.keyCount)
            #expect(dict.key(at: 0) == spec.firstKey)
            #expect(dict.key(at: dict.keyCount - 1) == spec.lastKey)
        } when: {
            !FileManager.default.fileExists(atPath: url.path)
        }
    }

    struct SkipDictionary: Error {}
}
