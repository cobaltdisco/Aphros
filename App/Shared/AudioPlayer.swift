import AVFoundation
import CryptoKit
import Foundation
import Observation

/// 发音播放。
///
/// **用 `AVPlayer` 不用 `AVAudioPlayer`**：后者放不了 Ogg Opus 而且**不报错**——
/// `play()` 返回 true，然后什么都不发生。目前只播 1.mdd 里的 mp3，
/// 但哪天把例句朗读（3.mdd，全是 Ogg Opus）接进来，用错了会静默失灵。见 ADR 0003。
@Observable
final class AudioPlayer {

    private var player: AVPlayer?
    /// 已经落盘的音频。mdd 取一次要解压一个块，同一个词反复点不该重复解。
    private var files: [String: URL] = [:]
    #if os(iOS)
    private var sessionReady = false
    #endif

    private(set) var lastError: String?

    func play(_ data: Data, reference: String) {
        do {
            let url = try files[reference] ?? write(data, reference: reference)
            files[reference] = url
            prepareSession()
            // 每次都新建：同一个 AVPlayer 连续 seek 到 0 再 play 在短音频上会漏播。
            player = AVPlayer(url: url)
            player?.play()
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// 写进临时目录。文件名用引用的 SHA-256，避免 mdd 里的反斜杠和 `#` 撞上文件系统。
    /// 扩展名必须留着——AVPlayer 靠它猜容器格式。
    private func write(_ data: Data, reference: String) throws -> URL {
        let digest = SHA256.hash(data: Data(reference.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let ext = (reference as NSString).pathExtension.lowercased()
        let url = FileManager.default.temporaryDirectory
            .appending(path: "audio-\(digest).\(ext.isEmpty ? "mp3" : ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    /// `.playback` 会**无视静音开关**。词典里点喇叭是明确的意图，
    /// 静音时不出声只会让人以为坏了。
    ///
    /// macOS 没有 `AVAudioSession`（整个类型 iOS 专属），也没有静音开关这回事，
    /// 这一步整个不存在。
    private func prepareSession() {
        #if os(iOS)
        guard !sessionReady else { return }
        sessionReady = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}
