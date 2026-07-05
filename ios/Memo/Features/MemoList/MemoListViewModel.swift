import Foundation
import Supabase

struct MemoCardData: Identifiable, Sendable {
    let id: UUID
    let memo: Memo
    let title: String
    let preview: String
    let meta: String?
    let classifying: Bool
}

@MainActor
@Observable
final class MemoListViewModel {
    var cards: [MemoCardData] = []
    var allCategories: [Category] = []
    var chips: [String] = ["전체"]
    var selectedFilter = "전체"
    var isLoading = false
    var errorText: String?

    private var memos: [Memo] = []
    private var categoryNames: [UUID: String] = [:]
    private var classifyWatch: Task<Void, Never>?
    private var watchCooldownUntil: Date = .distantPast
    let repo: MemoRepository = SupabaseMemoRepository()

    func categoryName(_ id: UUID?) -> String? { id.flatMap { categoryNames[$0] } }
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
            allCategories = cc.sorted { $0.name < $1.name }
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

    // Realtime을 놓쳐 "분류 중"이 안 풀릴 때 대비 — 분류 중 카드 있으면 백오프 재조회.
    // 무한루프 방지: 한 사이클 5회 고정(~31초) + 미해결 시 60초 쿨다운(재무장 억제).
    // 재진입 가드(classifyWatch != nil), sleep-먼저(타이트 루프 없음), weak self.
    private func watchClassifying() {
        guard cards.contains(where: { $0.classifying }) else {
            classifyWatch?.cancel(); classifyWatch = nil; return
        }
        guard classifyWatch == nil else { return }          // 이미 감시 중이면 중복 금지
        guard Date() >= watchCooldownUntil else { return }  // 쿨다운 중이면 재무장 금지
        classifyWatch = Task { [weak self] in
            var resolved = false
            for delay in [2, 3, 5, 8, 13] {                 // 정확히 5회 → 무한 아님
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.load()
                if !self.cards.contains(where: { $0.classifying }) { resolved = true; break }
            }
            guard let self else { return }
            if !resolved { self.watchCooldownUntil = Date().addingTimeInterval(60) } // 여전히 stuck → 1분 억제
            self.classifyWatch = nil
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
            return MemoCardData(id: m.id, memo: m, title: m.title.isEmpty ? "(제목 없음)" : m.title,
                                preview: m.preview, meta: meta,
                                classifying: !m.isClassified)
        }
        watchClassifying()
    }

    func selectFilter(_ f: String) { selectedFilter = f; rebuild() }

    func memo(_ id: UUID) -> Memo? { memos.first { $0.id == id } }

    // 메모의 카테고리 변경(사용자 오버라이드). 로컬 즉시 반영 + 서버 저장.
    func changeCategory(memoId: UUID, to categoryId: UUID?) async {
        if let idx = memos.firstIndex(where: { $0.id == memoId }) {
            memos[idx].categoryId = categoryId
            rebuild()
        }
        do { try await repo.setCategory(memoId: memoId, categoryId: categoryId) }
        catch { errorText = error.localizedDescription; await load() }
    }

    // 새 사용자 카테고리 생성(이미 있으면 재사용).
    func addCategory(_ name: String) async -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let cat = try await repo.createCategory(name: trimmed)
            if !allCategories.contains(where: { $0.id == cat.id }) {
                allCategories.append(cat)
                allCategories.sort { $0.name < $1.name }
                categoryNames[cat.id] = cat.name
            }
            return cat
        } catch { errorText = error.localizedDescription; return nil }
    }
}
