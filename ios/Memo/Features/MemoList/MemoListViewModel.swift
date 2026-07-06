import Foundation
import SwiftUI
import Supabase

struct MemoCardData: Identifiable, Sendable {
    let id: UUID
    let memo: Memo
    let title: String
    let preview: String
    let meta: String?
    let classifying: Bool
    let pinned: Bool
}

// 목록 정렬 기준.
enum MemoSort: String, CaseIterable, Identifiable {
    case newest, oldest, updated
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .newest: "최신순"
        case .oldest: "오래된순"
        case .updated: "수정순"
        }
    }
}

@MainActor
@Observable
final class MemoListViewModel {
    var cards: [MemoCardData] = []
    var allCategories: [Category] = []
    var chips: [String] = ["전체"]
    var chipsExpanded = false          // 칩 바 "더보기" 펼침 상태
    var categoryCounts: [UUID: Int] = [:]  // 카테고리별 메모 수(사용순 정렬·관리화면용)
    var selectedFilter = "전체"
    var searchText = "" { didSet { rebuild() } }   // 메모 본문 검색(로컬 필터)
    var sortOrder: MemoSort = .newest { didSet { rebuild() } }
    var uncategorizedOnly = false { didSet { rebuild() } }
    var semanticMode = false { didSet { semanticHits = nil; rebuild() } }  // 의미 검색 토글
    var searching = false           // 시맨틱 검색 진행 중
    private var semanticHits: [UUID]?   // 유사도순 결과 id(nil=미실행)
    var isLoading = false
    var offline = false
    var errorText: String?

    private let store = LocalStore()
    private var pendingOps: [PendingOp] = []
    private var didLoadQueue = false

    private var memos: [Memo] = []
    private var categoryNames: [UUID: String] = [:]
    private var classifyWatch: Task<Void, Never>?
    private var watchCooldownUntil: Date = .distantPast
    let repo: MemoRepository = SupabaseMemoRepository()

    func categoryName(_ id: UUID?) -> String? { id.flatMap { categoryNames[$0] } }
    // locale은 rebuild()에서 앱 언어 설정(AppSettings.appLanguage)에 맞춰 주입.
    private let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f
    }()

    func load() async {
        // 1) 캐시 먼저 — 앱 열면 즉시 표시(오프라인서도 열람)
        if memos.isEmpty, let snap = await store.loadSnapshot() {
            apply(memos: snap.memos, categories: snap.categories)
        }
        // 2) 대기 큐 복원(1회)
        if !didLoadQueue { didLoadQueue = true; pendingOps = await store.loadQueue() }
        // 3) 서버 갱신 → 4) 밀린 쓰기 flush
        await refreshFromServer()
        await flush()
    }

    private func refreshFromServer() async {
        isLoading = true; defer { isLoading = false }
        do {
            async let m = repo.fetchMemos()
            async let c = repo.fetchCategories()
            let (mm, cc) = try await (m, c)
            apply(memos: mm, categories: cc)
            replayPending()   // 아직 안 밀린 로컬 변경을 서버데이터 위에 재적용(낙관적 유지)
            offline = false
            await store.saveSnapshot(LocalSnapshot(memos: memos, categories: allCategories))
        } catch {
            offline = true
            if cards.isEmpty { errorText = error.localizedDescription }
        }
    }

    private func apply(memos mm: [Memo], categories cc: [Category]) {
        categoryNames = Dictionary(cc.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // 카테고리별 메모 수(미분류 제외) — 사용순 정렬·관리화면 표시에 재사용
        var counts: [UUID: Int] = [:]
        for m in mm { if let c = m.categoryId { counts[c, default: 0] += 1 } }
        categoryCounts = counts
        // 사용순(desc) → 동수면 이름순. 오래 안 쓴 큰 카테고리가 묻히지 않게 최근순 대신 사용순.
        let sorted = cc.sorted { a, b in
            let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
            return ca != cb ? ca > cb : a.name < b.name
        }
        allCategories = sorted
        memos = mm
        chips = ["전체"] + sorted.map(\.name)
        rebuild()
    }

    // 저장 = 로컬 우선(즉시 반영) + 큐 적재 → 온라인이면 즉시 flush. 분류는 서버 insert 후 Realtime.
    func create(content: String) async {
        let id = UUID(); let now = Date()
        memos.insert(Memo(id: id, content: content, categoryId: nil, embeddingModel: nil,
                          createdAt: now, updatedAt: now, deletedAt: nil), at: 0)
        rebuild()
        enqueue(.create(id: id, content: content, createdAt: now))
        await persistCache(); await flush()
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

    private func card(_ m: Memo) -> MemoCardData {
        let cat = m.categoryId.flatMap { categoryNames[$0] }
        let time = rel.localizedString(for: m.createdAt, relativeTo: Date())
        let meta = cat.map { "\($0) · \(time)" } ?? time
        return MemoCardData(id: m.id, memo: m,
                            title: m.title.isEmpty ? String(localized: "(제목 없음)") : m.title,
                            preview: m.preview, meta: meta,
                            classifying: !m.isClassified, pinned: m.isPinned)
    }

    private func rebuild() {
        rel.locale = AppSettings.shared.appLanguage.locale   // 상대시간도 앱 언어 따름
        // 시맨틱 모드: 유사도순 결과만(핀/정렬/카테고리 필터 미적용 — 검색 결과 뷰)
        if semanticMode {
            let byId = Dictionary(memos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cards = (semanticHits ?? []).compactMap { byId[$0] }.map(card)
            watchClassifying()
            return
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let filtered = memos.filter { m in
            // 미분류만 보기
            if uncategorizedOnly, m.categoryId != nil { return false }
            // 카테고리 필터
            let catOK: Bool
            if selectedFilter == "전체" { catOK = true }
            else if let cid = m.categoryId { catOK = categoryNames[cid] == selectedFilter }
            else { catOK = false }
            guard catOK else { return false }
            // 검색 필터(본문) — AND 결합
            return q.isEmpty || m.content.localizedCaseInsensitiveContains(q)
        }
        let sorted = filtered.sorted { a, b in
            // 핀 우선(#3에서 isPinned 추가 후 유효), 그다음 정렬 기준
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            switch sortOrder {
            case .newest: return a.createdAt > b.createdAt
            case .oldest: return a.createdAt < b.createdAt
            case .updated: return a.updatedAt > b.updatedAt
            }
        }
        cards = sorted.map(card)
        watchClassifying()
    }

    // 시맨틱 검색 실행(제출 시). 결과 id를 로컬 memos와 매칭해 유사도순 표시.
    func runSemanticSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard semanticMode, !q.isEmpty else { semanticHits = nil; rebuild(); return }
        searching = true; defer { searching = false }
        do {
            let hits = try await repo.searchSemantic(query: q, count: 30)
            semanticHits = hits.map(\.id)
        } catch {
            errorText = error.localizedDescription
            semanticHits = []
        }
        rebuild()
    }

    func selectFilter(_ f: String) { selectedFilter = f; rebuild() }

    func memo(_ id: UUID) -> Memo? { memos.first { $0.id == id } }

    func updateMemo(memoId: UUID, content: String) async {
        if let i = memos.firstIndex(where: { $0.id == memoId }) {
            memos[i].content = content; memos[i].updatedAt = Date(); rebuild()
        }
        enqueue(.update(id: memoId, content: content))
        await persistCache(); await flush()
    }

    func deleteMemo(_ id: UUID) async {
        memos.removeAll { $0.id == id }; rebuild()
        enqueue(.delete(id: id))
        await persistCache(); await flush()
    }

    // 오프라인 쓰기 큐 -------------------------------------------------------
    private func enqueue(_ op: PendingOp) { pendingOps.append(op) }

    private func persistCache() async {
        await store.saveSnapshot(LocalSnapshot(memos: memos, categories: allCategories))
        await store.saveQueue(pendingOps)
    }

    // 밀린 쓰기를 순서대로 서버에 반영. 실패(오프라인 등) 시 그 지점서 멈추고 큐 유지.
    func flush() async {
        guard !pendingOps.isEmpty else { return }
        var remaining = pendingOps
        while let op = remaining.first {
            do { try await applyRemote(op); remaining.removeFirst() }
            catch { break }
        }
        let progressed = remaining.count != pendingOps.count
        pendingOps = remaining
        await store.saveQueue(pendingOps)
        if progressed && pendingOps.isEmpty { await refreshFromServer() } // 다 밀렸으면 서버 최신으로
    }

    private func applyRemote(_ op: PendingOp) async throws {
        switch op {
        case let .create(id, content, _):     try await repo.createMemo(id: id, content: content)
        case let .update(id, content):        try await repo.updateMemo(memoId: id, content: content)
        case let .delete(id):                 try await repo.softDeleteMemo(id: id)
        case let .setCategory(id, categoryId): try await repo.setCategory(memoId: id, categoryId: categoryId)
        case let .setPinned(id, pinned):       try await repo.setPinned(memoId: id, pinned: pinned)
        }
    }

    // 서버 데이터 위에 아직 안 밀린 로컬 변경 재적용(낙관적 유지).
    private func replayPending() {
        for op in pendingOps {
            switch op {
            case let .create(id, content, createdAt):
                if !memos.contains(where: { $0.id == id }) {
                    memos.insert(Memo(id: id, content: content, categoryId: nil, embeddingModel: nil,
                                      createdAt: createdAt, updatedAt: createdAt, deletedAt: nil), at: 0)
                }
            case let .update(id, content):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].content = content }
            case let .delete(id):
                memos.removeAll { $0.id == id }
            case let .setCategory(id, categoryId):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].categoryId = categoryId }
            case let .setPinned(id, pinned):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].isPinned = pinned }
            }
        }
        rebuild()
    }

    // 핀 토글(로컬 우선 + 큐). 정렬 최상단 반영은 rebuild.
    func togglePin(memoId: UUID) async {
        guard let idx = memos.firstIndex(where: { $0.id == memoId }) else { return }
        let pinned = !memos[idx].isPinned
        memos[idx].isPinned = pinned; rebuild()
        enqueue(.setPinned(id: memoId, pinned: pinned))
        await persistCache(); await flush()
    }

    func isPinned(_ id: UUID) -> Bool { memos.first { $0.id == id }?.isPinned ?? false }

    // 카테고리 변경(사용자 오버라이드). 로컬 우선 + 큐.
    func changeCategory(memoId: UUID, to categoryId: UUID?) async {
        if let idx = memos.firstIndex(where: { $0.id == memoId }) {
            memos[idx].categoryId = categoryId; rebuild()
        }
        enqueue(.setCategory(id: memoId, categoryId: categoryId))
        await persistCache(); await flush()
    }

    // 새 사용자 카테고리 생성(이미 있으면 재사용).
    func addCategory(_ name: String) async -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let cat = try await repo.createCategory(name: trimmed)
            if !allCategories.contains(where: { $0.id == cat.id }) {
                allCategories.append(cat)
                // 사용순(desc)·이름순 정렬 유지 — 새 카테고리는 count 0이라 뒤로.
                allCategories.sort { a, b in
                    let ca = categoryCounts[a.id] ?? 0, cb = categoryCounts[b.id] ?? 0
                    return ca != cb ? ca > cb : a.name < b.name
                }
                categoryNames[cat.id] = cat.name
            }
            return cat
        } catch { errorText = error.localizedDescription; return nil }
    }

    // 카테고리 관리(온라인 즉시 실행 + 재로딩). 오프라인 큐 대상 아님.
    // 이름변경: unique(user_id,name) 충돌 시 실패 → 호출부에서 병합 유도.
    func renameCategory(_ id: UUID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do { try await repo.renameCategory(id: id, name: trimmed); await load(); return true }
        catch { errorText = error.localizedDescription; return false }
    }

    func mergeCategory(_ source: UUID, into target: UUID) async -> Bool {
        guard source != target else { return false }
        do { try await repo.mergeCategory(source: source, into: target); await load(); return true }
        catch { errorText = error.localizedDescription; return false }
    }
}
