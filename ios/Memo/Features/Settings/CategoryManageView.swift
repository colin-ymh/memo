import SwiftUI
import UniformTypeIdentifiers

// 폴더 편집기 시트의 모드(생성/편집). 파일 스코프라 두 뷰가 공유.
enum FolderEditorMode: Identifiable {
    case create(parent: UUID?)
    case edit(Folder)
    var id: String {
        switch self {
        case .create(let p): return "create-\(p?.uuidString ?? "root")"
        case .edit(let f):   return "edit-\(f.id.uuidString)"
        }
    }
}

// 폴더 관리 — 트리 편집. 생성/이름·설명 수정/드래그 이동(순서+뎁스)/삭제(빈 폴더만).
// 드래그: 행별 DropDelegate가 그 행의 로컬 위치로 위/가운데/아래 판정(mokjang 참고 방식).
struct FolderManageView: View {
    @Bindable var vm: MemoListViewModel

    @State private var editor: FolderEditorMode?
    @State private var busy = false

    // 드래그 상태
    @State private var draggingId: UUID?
    @State private var dropTargetId: UUID?
    @State private var dropZone: DropZone = .after
    @State private var rowHeights: [UUID: CGFloat] = [:]

    private let indentUnit: CGFloat = 16   // rowView 들여쓰기(depth*16)와 동일

    var body: some View {
        ScrollView {
            let tree = vm.orderedTree()
            VStack(alignment: .leading, spacing: Space.x1) {
                if tree.isEmpty {
                    Text("아직 폴더가 없어요. 오른쪽 위 ＋로 첫 폴더를 만들어보세요.")
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.x4)
                } else {
                    ForEach(tree, id: \.folder.id) { row in
                        rowView(row.folder, depth: row.depth)
                    }
                    Text("폴더를 끌어 위/아래 모서리에 놓으면 순서·형제, 폴더 가운데에 놓으면 그 안으로. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 비어 있는 폴더만, 최대 3단계까지.")
                        .font(.appCaption).foregroundStyle(AppColor.textTertiary)
                        .padding(.horizontal, Space.x2).padding(.top, Space.x4)
                }
            }
            .padding(Space.x3)
            .onPreferenceChange(RowHeightKey.self) { rowHeights = $0 }
        }
        .disabled(busy)
        .navigationTitle("폴더 관리")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .create(parent: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editor) { mode in FolderEditorView(mode: mode, vm: vm) }
    }

    private func rowView(_ f: Folder, depth: Int) -> some View {
        let isTarget = draggingId != nil && dropTargetId == f.id
        let hasChildren = vm.childCount(f.id) > 0
        return HStack(spacing: Space.x2) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * indentUnit) }
            Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(AppColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).foregroundStyle(AppColor.textPrimary)
                if let d = f.description, !d.isEmpty {
                    Text(d).font(.appCaption).foregroundStyle(AppColor.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            Text("\(vm.memoCount(f.id))")
                .font(.appCaption).foregroundStyle(AppColor.textTertiary)
            if vm.depth(of: f.id) < kMaxFolderDepth {
                Button { editor = .create(parent: f.id) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(AppColor.accent)
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button { editor = .edit(f) } label: { Label("편집", systemImage: "pencil") }
                if vm.canDelete(f.id) {
                    Button(role: .destructive) {
                        Task { busy = true; _ = await vm.deleteFolder(id: f.id); busy = false }
                    } label: { Label("삭제", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(.vertical, Space.x3).padding(.horizontal, Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { g in
            Color.clear.preference(key: RowHeightKey.self, value: [f.id: g.size.height])
        })
        .background((isTarget && dropZone == .into) ? AppColor.accent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        // 삽입선: 위 모서리=before, 아래 모서리=after(대상이 자식 보유면 한 단계 안쪽 들여쓰기).
        .overlay(alignment: .top)    { if isTarget && dropZone == .before { insLine(depth: depth) } }
        .overlay(alignment: .bottom) { if isTarget && dropZone == .after  { insLine(depth: hasChildren ? depth + 1 : depth) } }
        .opacity(draggingId == f.id ? 0.35 : 1)
        .contentShape(Rectangle())
        .onDrag {
            draggingId = f.id
            return NSItemProvider(object: f.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.text], delegate: RowDropDelegate(
            targetId: f.id,
            height: rowHeights[f.id] ?? 44,
            draggingId: $draggingId,
            dropTargetId: $dropTargetId,
            dropZone: $dropZone,
            canNest: { canNestOnto($0) },
            perform: { dragged, target, zone in performMove(dragged, target, zone) }
        ))
    }

    private func insLine(depth: Int) -> some View {
        Capsule().fill(AppColor.accent).frame(height: 3)
            .padding(.leading, Space.x3 + CGFloat(depth) * indentUnit)
            .padding(.trailing, Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }

    // 드래그 서브트리를 제외한 평탄 배열. depth 0-based→1-based(+1).
    private func flat(excluding dragging: UUID) -> [FlatFolder] {
        let excluded = vm.descendantIds(of: dragging).union([dragging])
        return vm.orderedTree()
            .filter { !excluded.contains($0.folder.id) }
            .map { FlatFolder(id: $0.folder.id, parentId: $0.folder.parentId, depth: $0.depth + 1) }
    }

    private func canNestOnto(_ targetId: UUID) -> Bool {
        guard let dragging = draggingId else { return false }
        return FolderReorder.canNest(flat: flat(excluding: dragging), targetId: targetId,
                                     subtreeHeight: vm.subtreeHeight(of: dragging), maxDepth: kMaxFolderDepth)
    }

    private func performMove(_ dragged: UUID, _ target: UUID, _ zone: DropZone) {
        let f = flat(excluding: dragged)
        guard let res = FolderReorder.resolve(flat: f, targetId: target, zone: zone) else { return }
        Task { busy = true; _ = await vm.moveFolder(id: dragged, toParent: res.parentId, index: res.index); busy = false }
    }
}

// 행별 드롭 처리 — 그 행의 로컬 위치로 before/into/after 판정(글로벌 좌표 불필요).
private struct RowDropDelegate: DropDelegate {
    let targetId: UUID
    let height: CGFloat
    @Binding var draggingId: UUID?
    @Binding var dropTargetId: UUID?
    @Binding var dropZone: DropZone
    let canNest: (UUID) -> Bool
    let perform: (UUID, UUID, DropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool { draggingId != nil && draggingId != targetId }
    func dropEntered(info: DropInfo) { refresh(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { refresh(info); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { if dropTargetId == targetId { dropTargetId = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let d = draggingId, d != targetId else { clear(); return false }
        perform(d, targetId, zone(info))
        clear()
        return true
    }

    private func clear() { dropTargetId = nil; draggingId = nil }

    private func zone(_ info: DropInfo) -> DropZone {
        let rel = height > 0 ? info.location.y / height : 0.5
        if rel < 0.25 { return .before }
        if rel > 0.75 { return .after }
        return canNest(targetId) ? .into : .after
    }

    private func refresh(_ info: DropInfo) {
        guard let d = draggingId, d != targetId else { return }
        dropTargetId = targetId
        dropZone = zone(info)
    }
}

// 행 높이 수집 — DropDelegate가 로컬 y를 비율로 환산할 때 사용.
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// 폴더 생성/편집 시트.
struct FolderEditorView: View {
    let mode: FolderEditorMode
    let vm: MemoListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var desc = ""
    @State private var busy = false

    private var isEdit: Bool { if case .edit = mode { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section("제목") { TextField("폴더 이름", text: $title) }
                Section("설명 (AI 분류 힌트)") {
                    TextField("이 폴더엔 어떤 메모가 들어가나요?", text: $desc, axis: .vertical)
                        .lineLimit(2...4)
                }
                if case .create(let parent) = mode, let parent, let path = vm.folderPath(parent) {
                    Section { LabeledContent("상위 폴더", value: path) }
                }
            }
            .navigationTitle(isEdit ? "폴더 편집" : "새 폴더")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .onAppear {
                if case .edit(let f) = mode { title = f.title; desc = f.description ?? "" }
            }
        }
    }

    private func save() async {
        busy = true; defer { busy = false }
        let ok: Bool
        switch mode {
        case .create(let parent):
            ok = (await vm.createFolder(title: title, description: desc, parentId: parent)) != nil
        case .edit(let f):
            ok = await vm.updateFolder(id: f.id, title: title, description: desc)
        }
        if ok { dismiss() }
    }
}
