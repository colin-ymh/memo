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

// 폴더 트리 최대 뎁스(서버 트리거와 동일). 최상위 = 1.
let kMaxFolderDepth = 3

// 평탄화한 트리 노드(들여쓰기 depth 포함). ForEach용 Identifiable.
struct FolderNode: Identifiable, Sendable {
    let folder: Folder
    let depth: Int
    var id: UUID { folder.id }
}

@MainActor
@Observable
final class MemoListViewModel {
    var cards: [MemoCardData] = []
    var allFolders: [Folder] = []
    var folderMemoCounts: [UUID: Int] = [:]   // 폴더별 직속 메모 수(관리화면 표시)

    // 폴더 브라우저 네비게이션 상태.
    var currentFolderId: UUID?    // nil = 전체(가상 루트)
    var unclassifiedMode = false  // 미분류 버킷 보기

    var searchText = "" { didSet { rebuild() } }   // 메모 본문 검색(로컬 필터)
    var sortOrder: MemoSort = .newest { didSet { rebuild() } }
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
    private var foldersById: [UUID: Folder] = [:]
    private var classifyWatch: Task<Void, Never>?
    private var watchCooldownUntil: Date = .distantPast
    let repo: MemoRepository = SupabaseMemoRepository()

    // locale은 rebuild()에서 앱 언어 설정(AppSettings.appLanguage)에 맞춰 주입.
    private let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f
    }()

    // MARK: - 폴더 트리 헬퍼

    func folderTitle(_ id: UUID?) -> String? { id.flatMap { foldersById[$0]?.title } }

    // 루트→해당 폴더까지 경로 문자열("개발 / iOS"). nil이면 nil.
    func folderPath(_ id: UUID?) -> String? {
        guard let id, foldersById[id] != nil else { return nil }
        var parts: [String] = []
        var cur: UUID? = id
        while let c = cur, let f = foldersById[c] {
            parts.append(f.title); cur = f.parentId
        }
        return parts.reversed().joined(separator: " / ")
    }

    // 특정 부모의 자식 폴더(제목순). parent nil = 최상위 폴더들.
    func subfolders(of parent: UUID?) -> [Folder] {
        allFolders.filter { $0.parentId == parent }.sorted { $0.title < $1.title }
    }
    var currentSubfolders: [Folder] { subfolders(of: currentFolderId) }

    // 현재 폴더의 조상 체인(루트→현재), 브레드크럼용.
    var breadcrumb: [Folder] {
        guard let id = currentFolderId else { return [] }
        var chain: [Folder] = []
        var cur: UUID? = id
        while let c = cur, let f = foldersById[c] { chain.append(f); cur = f.parentId }
        return chain.reversed()
    }

    var currentTitle: String {
        if unclassifiedMode { return String(localized: "미분류") }
        return folderTitle(currentFolderId) ?? String(localized: "전체")
    }

    // 폴더 깊이(최상위=1). 새 하위폴더/이동 가능여부 판단에 사용.
    func depth(of id: UUID) -> Int {
        var d = 1; var cur = foldersById[id]?.parentId
        while let c = cur { d += 1; cur = foldersById[c]?.parentId }
        return d
    }
    // 트리를 DFS 순서로 평탄화(관리/피커 들여쓰기 표시용). depth 0-based.
    func orderedTree() -> [FolderNode] {
        var out: [FolderNode] = []
        func walk(_ parent: UUID?, _ d: Int) {
            for f in subfolders(of: parent) { out.append(FolderNode(folder: f, depth: d)); walk(f.id, d + 1) }
        }
        walk(nil, 0)
        return out
    }

    // 특정 폴더의 모든 후손 id(이동 시 자기 자신·후손을 부모 후보에서 제외).
    func descendantIds(of id: UUID) -> Set<UUID> {
        var acc: Set<UUID> = []
        func walk(_ p: UUID) { for c in allFolders where c.parentId == p { acc.insert(c.id); walk(c.id) } }
        walk(id)
        return acc
    }

    func childCount(_ id: UUID) -> Int { allFolders.filter { $0.parentId == id }.count }
    func memoCount(_ id: UUID) -> Int { folderMemoCounts[id] ?? 0 }
    // 빈 폴더만 삭제 가능(직속 메모 0 && 자식 0).
    func canDelete(_ id: UUID) -> Bool { childCount(id) == 0 && memoCount(id) == 0 }

    // MARK: - 로딩/동기화

    func load() async {
        // 1) 캐시 먼저 — 앱 열면 즉시 표시(오프라인서도 열람)
        if memos.isEmpty, let snap = await store.loadSnapshot() {
            apply(memos: snap.memos, folders: snap.folders)
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
            async let f = repo.fetchFolders()
            let (mm, ff) = try await (m, f)
            apply(memos: mm, folders: ff)
            replayPending()   // 아직 안 밀린 로컬 변경을 서버데이터 위에 재적용(낙관적 유지)
            offline = false
            await store.saveSnapshot(LocalSnapshot(memos: memos, folders: allFolders))
        } catch {
            offline = true
            if cards.isEmpty { errorText = error.localizedDescription }
        }
    }

    private func apply(memos mm: [Memo], folders ff: [Folder]) {
        foldersById = Dictionary(ff.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var counts: [UUID: Int] = [:]
        for m in mm { if let f = m.folderId { counts[f, default: 0] += 1 } }
        folderMemoCounts = counts
        allFolders = ff.sorted { $0.title < $1.title }
        memos = mm
        // 현재 보고 있던 폴더가 사라졌으면 루트로.
        if let cur = currentFolderId, foldersById[cur] == nil {
            currentFolderId = nil; unclassifiedMode = false
        }
        rebuild()
    }

    // MARK: - 네비게이션

    func enterFolder(_ id: UUID) { unclassifiedMode = false; currentFolderId = id; rebuild() }
    func enterUnclassified() { unclassifiedMode = true; currentFolderId = nil; rebuild() }
    func goToRoot() { unclassifiedMode = false; currentFolderId = nil; rebuild() }
    func goUp() {
        if unclassifiedMode { goToRoot(); return }
        currentFolderId = currentFolderId.flatMap { foldersById[$0]?.parentId }
        rebuild()
    }

    // MARK: - 메모 작성/편집

    func create(content: String) async {
        let id = UUID(); let now = Date()
        memos.insert(Memo(id: id, content: content, folderId: nil, embeddingModel: nil,
                          createdAt: now, updatedAt: now, deletedAt: nil), at: 0)
        rebuild()
        enqueue(.create(id: id, content: content, createdAt: now))
        await persistCache(); await flush()
    }

    // Realtime: memos 변경 시 재로딩(분류 완료 → folder/embedding 채워짐 반영).
    func startRealtime() async {
        let channel = SupabaseManager.client.channel("public:memos")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "memos")
        await channel.subscribe()
        for await _ in changes {
            await load()
        }
    }

    // Realtime을 놓쳐 "분류 중"이 안 풀릴 때 대비 — 분류 중 카드 있으면 백오프 재조회.
    private func watchClassifying() {
        guard cards.contains(where: { $0.classifying }) else {
            classifyWatch?.cancel(); classifyWatch = nil; return
        }
        guard classifyWatch == nil else { return }
        guard Date() >= watchCooldownUntil else { return }
        classifyWatch = Task { [weak self] in
            var resolved = false
            for delay in [2, 3, 5, 8, 13] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.load()
                if !self.cards.contains(where: { $0.classifying }) { resolved = true; break }
            }
            guard let self else { return }
            if !resolved { self.watchCooldownUntil = Date().addingTimeInterval(60) }
            self.classifyWatch = nil
        }
    }

    private func card(_ m: Memo) -> MemoCardData {
        let folder = folderTitle(m.folderId)
        let time = rel.localizedString(for: m.createdAt, relativeTo: Date())
        let meta = folder.map { "\($0) · \(time)" } ?? time
        return MemoCardData(id: m.id, memo: m,
                            title: m.title.isEmpty ? String(localized: "(제목 없음)") : m.title,
                            preview: m.preview, meta: meta,
                            classifying: !m.isClassified, pinned: m.isPinned)
    }

    private func rebuild() {
        rel.locale = AppSettings.shared.appLanguage.locale
        // 시맨틱 모드: 유사도순 결과만(폴더 필터 미적용 — 검색 결과 뷰)
        if semanticMode {
            let byId = Dictionary(memos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            cards = (semanticHits ?? []).compactMap { byId[$0] }.map(card)
            watchClassifying()
            return
        }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        // 폴더 스코프: 미분류 / 특정 폴더 직속 / 전체.
        let base: [Memo]
        if unclassifiedMode { base = memos.filter { $0.folderId == nil } }
        else if let f = currentFolderId { base = memos.filter { $0.folderId == f } }
        else { base = memos }
        let filtered = base.filter { q.isEmpty || $0.content.localizedCaseInsensitiveContains(q) }
        let sorted = filtered.sorted { a, b in
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

    func runSemanticSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard semanticMode, !q.isEmpty else { semanticHits = nil; rebuild(); return }
        searching = true; defer { searching = false }
        do {
            let hits = try await repo.searchSemantic(query: q, count: 12)
            semanticHits = hits.map(\.id)
        } catch {
            errorText = error.localizedDescription
            semanticHits = []
        }
        rebuild()
    }

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

    // MARK: - 오프라인 쓰기 큐

    private func enqueue(_ op: PendingOp) { pendingOps.append(op) }

    private func persistCache() async {
        await store.saveSnapshot(LocalSnapshot(memos: memos, folders: allFolders))
        await store.saveQueue(pendingOps)
    }

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
        if progressed && pendingOps.isEmpty { await refreshFromServer() }
    }

    private func applyRemote(_ op: PendingOp) async throws {
        switch op {
        case let .create(id, content, _):   try await repo.createMemo(id: id, content: content)
        case let .update(id, content):      try await repo.updateMemo(memoId: id, content: content)
        case let .delete(id):               try await repo.softDeleteMemo(id: id)
        case let .setFolder(id, folderId):  try await repo.setFolder(memoId: id, folderId: folderId)
        case let .setPinned(id, pinned):    try await repo.setPinned(memoId: id, pinned: pinned)
        }
    }

    private func replayPending() {
        for op in pendingOps {
            switch op {
            case let .create(id, content, createdAt):
                if !memos.contains(where: { $0.id == id }) {
                    memos.insert(Memo(id: id, content: content, folderId: nil, embeddingModel: nil,
                                      createdAt: createdAt, updatedAt: createdAt, deletedAt: nil), at: 0)
                }
            case let .update(id, content):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].content = content }
            case let .delete(id):
                memos.removeAll { $0.id == id }
            case let .setFolder(id, folderId):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].folderId = folderId }
            case let .setPinned(id, pinned):
                if let i = memos.firstIndex(where: { $0.id == id }) { memos[i].isPinned = pinned }
            }
        }
        rebuild()
    }

    func togglePin(memoId: UUID) async {
        guard let idx = memos.firstIndex(where: { $0.id == memoId }) else { return }
        let pinned = !memos[idx].isPinned
        memos[idx].isPinned = pinned; rebuild()
        enqueue(.setPinned(id: memoId, pinned: pinned))
        await persistCache(); await flush()
    }

    func isPinned(_ id: UUID) -> Bool { memos.first { $0.id == id }?.isPinned ?? false }
    func folderId(of memoId: UUID) -> UUID? { memos.first { $0.id == memoId }?.folderId }

    // 메모 폴더 변경(사용자 오버라이드). 로컬 우선 + 큐.
    func changeFolder(memoId: UUID, to folderId: UUID?) async {
        if let idx = memos.firstIndex(where: { $0.id == memoId }) {
            memos[idx].folderId = folderId; rebuild()
        }
        enqueue(.setFolder(id: memoId, folderId: folderId))
        await persistCache(); await flush()
    }

    // MARK: - 폴더 관리(온라인 즉시 실행 + 재로딩. 오프라인 큐 대상 아님)

    func createFolder(title: String, description: String?, parentId: UUID?) async -> Folder? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let folder = try await repo.createFolder(
                title: t, description: (desc?.isEmpty == false) ? desc : nil, parentId: parentId)
            await load()
            return folder
        } catch { errorText = error.localizedDescription; return nil }
    }

    func updateFolder(id: UUID, title: String, description: String?) async -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await repo.updateFolder(id: id, title: t, description: (desc?.isEmpty == false) ? desc : nil)
            await load(); return true
        } catch { errorText = error.localizedDescription; return false }
    }

    // 폴더 이동. 깊이 초과·순환은 서버 트리거가 거부.
    func reparentFolder(id: UUID, to parentId: UUID?) async -> Bool {
        guard id != parentId else { return false }
        do { try await repo.reparentFolder(id: id, parentId: parentId); await load(); return true }
        catch { errorText = error.localizedDescription; return false }
    }

    // 빈 폴더만 삭제.
    func deleteFolder(id: UUID) async -> Bool {
        guard canDelete(id) else {
            errorText = String(localized: "폴더에 메모나 하위 폴더가 있어 삭제할 수 없습니다. 먼저 비워주세요.")
            return false
        }
        do { try await repo.deleteFolder(id: id); await load(); return true }
        catch { errorText = error.localizedDescription; return false }
    }
}
