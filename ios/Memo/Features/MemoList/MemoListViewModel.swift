import Foundation
import Supabase

struct MemoCardData: Identifiable, Sendable {
    let id: UUID
    let title: String
    let preview: String
    let meta: String?
    let classifying: Bool
}

@MainActor
@Observable
final class MemoListViewModel {
    var cards: [MemoCardData] = []
    var chips: [String] = ["전체"]
    var selectedFilter = "전체"
    var isLoading = false
    var errorText: String?

    private var memos: [Memo] = []
    private var categoryNames: [UUID: String] = [:]
    private let repo: MemoRepository = SupabaseMemoRepository()
    private let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "ko_KR"); f.unitsStyle = .short
        return f
    }()

    func load() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let m = repo.fetchMemos()
            async let c = repo.fetchCategories()
            let (mm, cc) = try await (m, c)
            categoryNames = Dictionary(cc.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            memos = mm
            chips = ["전체"] + cc.map(\.name)
            rebuild()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // 저장(로그인된 사용자로 INSERT). 낙관적으로 목록 맨 앞에 추가 → 분류는 서버가 채움(Realtime 반영).
    func create(content: String) async {
        do {
            let memo = try await repo.createMemo(content: content)
            memos.insert(memo, at: 0)
            rebuild()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // Realtime: memos 변경 시 재로딩(분류 완료 → category/embedding 채워짐 반영).
    func startRealtime() async {
        let channel = SupabaseManager.client.channel("public:memos")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "memos")
        await channel.subscribe()
        for await _ in changes {
            await load()
        }
    }

    private func rebuild() {
        let filtered = memos.filter { m in
            guard selectedFilter != "전체" else { return true }
            guard let cid = m.categoryId else { return false }
            return categoryNames[cid] == selectedFilter
        }
        cards = filtered.map { m in
            let cat = m.categoryId.flatMap { categoryNames[$0] }
            let time = rel.localizedString(for: m.createdAt, relativeTo: Date())
            let meta = cat.map { "\($0) · \(time)" } ?? time
            return MemoCardData(id: m.id, title: m.title.isEmpty ? "(제목 없음)" : m.title,
                                preview: m.preview, meta: meta,
                                classifying: !m.isClassified)
        }
    }

    func selectFilter(_ f: String) { selectedFilter = f; rebuild() }
}
