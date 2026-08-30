import Foundation

/// 解压后区块的 LRU 缓存，按**字节数**限容而不是条数——mdx 的区块约 64 KB，
/// mdd 的区块可能几 MB，按条数限容会让 mdd 把内存吃穿。
///
/// 单块超过总容量时不缓存（直接返回给调用方用完就丢），避免一块把整个缓存挤空。
///
/// 加锁是为了让 `MDict` 能标成 Sendable：词典打开后除了这个缓存全是只读的，
/// 界面层要在后台线程建索引、在主线程取正文，没有锁就过不了 Swift 6 的并发检查。
final class BlockCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int: Data] = [:]
    private var recency: [Int] = []          // 最近用过的排在末尾
    private var bytes = 0
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func value(for key: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }

        guard let hit = storage[key] else { return nil }
        touch(key)
        return hit
    }

    func insert(_ value: Data, for key: Int) {
        lock.lock(); defer { lock.unlock() }

        guard value.count <= capacity else { return }
        if let old = storage.removeValue(forKey: key) {
            bytes -= old.count
            recency.removeAll { $0 == key }
        }
        storage[key] = value
        recency.append(key)
        bytes += value.count
        while bytes > capacity, let oldest = recency.first {
            recency.removeFirst()
            bytes -= storage.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }

        storage.removeAll(keepingCapacity: false)
        recency.removeAll(keepingCapacity: false)
        bytes = 0
    }

    /// 调用方已经持锁。
    private func touch(_ key: Int) {
        guard recency.last != key else { return }
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
