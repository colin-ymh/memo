import Foundation

// 오프라인 로컬 저장소 — App Group 컨테이너에 스냅샷/대기큐를 파일로.
// (App Group 미프로비저닝 시 Documents로 폴백 → 시뮬/개발서도 동작)
struct LocalSnapshot: Codable, Sendable {
    var memos: [Memo] = []
    var categories: [Category] = []
    var savedAt: Date = .init()
}

actor LocalStore {
    static let appGroup = "group.com.duovelop.memo"
    private let snapshotName = "snapshot.json"
    private let queueName = "pending-ops.json"

    private var baseURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var snapshotURL: URL { baseURL.appendingPathComponent(snapshotName) }
    private var queueURL: URL { baseURL.appendingPathComponent(queueName) }

    // 스냅샷(읽기 캐시) -------------------------------------------------------
    func loadSnapshot() -> LocalSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder.iso.decode(LocalSnapshot.self, from: data)
    }
    func saveSnapshot(_ snap: LocalSnapshot) {
        guard let data = try? JSONEncoder.iso.encode(snap) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    // 대기 큐(쓰기 오프라인) — Tier B에서 사용 -------------------------------
    func loadQueue() -> [PendingOp] {
        guard let data = try? Data(contentsOf: queueURL) else { return [] }
        return (try? JSONDecoder.iso.decode([PendingOp].self, from: data)) ?? []
    }
    func saveQueue(_ ops: [PendingOp]) {
        guard let data = try? JSONEncoder.iso.encode(ops) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }
}

// 오프라인 쓰기 대기 작업(Tier B).
enum PendingOp: Codable, Sendable {
    case create(id: UUID, content: String, createdAt: Date)
    case update(id: UUID, content: String)
    case delete(id: UUID)
    case setCategory(id: UUID, categoryId: UUID?)
    case setPinned(id: UUID, pinned: Bool)
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
