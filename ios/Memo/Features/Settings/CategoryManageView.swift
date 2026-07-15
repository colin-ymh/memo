import SwiftUI

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

// 폴더 관리 — 트리 편집. 생성/수정/드래그 이동(순서+뎁스)/삭제.
// 드래그: .draggable + .dropDestination(행별). 드롭 시 로컬 location.y로 위/가운데/아래 판정.
// 최상위로 빼기는 상단 "전체" 드롭행으로도 가능.
struct FolderManageView: View {
    @Bindable var vm: MemoListViewModel

    @State private var editor: FolderEditorMode?
    @State private var busy = false

    @State private var dropTargetId: UUID?         // 현재 하이라이트 행
    @State private var rootTargeted = false        // "전체" 드롭행 하이라이트
    @State private var rowHeights: [UUID: CGFloat] = [:]

    private let indentUnit: CGFloat = 16

    var body: some View {
        ScrollView {
            let tree = vm.orderedTree()
            VStack(alignment: .leading, spacing: Space.x1) {
                rootDropRow
                if tree.isEmpty {
                    Text("아직 폴더가 없어요. 오른쪽 위 ＋로 첫 폴더를 만들어보세요.")
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.x4)
                } else {
                    ForEach(tree, id: \.folder.id) { row in
                        rowView(row.folder, depth: row.depth)
                    }
                    Text("폴더를 끌어 다른 폴더 위/아래에 놓으면 순서·형제, 가운데에 놓으면 그 안으로. 맨 위 ‘전체’에 놓으면 최상위로. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 빈 폴더만, 최대 3단계.")
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

    // 최상위(전체)로 빼내는 드롭행 — 여기 놓으면 root 맨 뒤.
    private var rootDropRow: some View {
        HStack(spacing: Space.x2) {
            Image(systemName: "tray.full").font(.system(size: 14)).foregroundStyle(AppColor.textSecondary)
            Text("전체 (최상위)").foregroundStyle(AppColor.textSecondary)
            Spacer()
        }
        .padding(.vertical, Space.x3).padding(.horizontal, Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rootTargeted ? AppColor.accent.opacity(0.18) : AppColor.fieldBg.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let dragged = UUID(uuidString: s) else { return false }
            let rootCount = vm.subfolders(of: nil).filter { $0.id != dragged }.count
            Task { busy = true; _ = await vm.moveFolder(id: dragged, toParent: nil, index: rootCount); busy = false }
            return true
        } isTargeted: { rootTargeted = $0 }
    }

    private func rowView(_ f: Folder, depth: Int) -> some View {
        HStack(spacing: Space.x2) {
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
        .background(dropTargetId == f.id ? AppColor.accent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .draggable(f.id.uuidString)
        .dropDestination(for: String.self) { items, location in
            guard let s = items.first, let dragged = UUID(uuidString: s), dragged != f.id else { return false }
            let h = rowHeights[f.id] ?? 44
            let rel = h > 0 ? location.y / h : 0.5
            let zone: DropZone = rel < 0.25 ? .before
                : (rel > 0.75 ? .after
                   : (canNestOnto(f.id, dragged: dragged) ? .into : .after))
            performMove(dragged, f.id, zone)
            return true
        } isTargeted: { over in
            dropTargetId = over ? f.id : (dropTargetId == f.id ? nil : dropTargetId)
        }
    }

    // 드래그 서브트리를 제외한 평탄 배열. depth 0-based→1-based(+1).
    private func flat(excluding dragging: UUID) -> [FlatFolder] {
        let excluded = vm.descendantIds(of: dragging).union([dragging])
        return vm.orderedTree()
            .filter { !excluded.contains($0.folder.id) }
            .map { FlatFolder(id: $0.folder.id, parentId: $0.folder.parentId, depth: $0.depth + 1) }
    }

    private func canNestOnto(_ targetId: UUID, dragged: UUID) -> Bool {
        FolderReorder.canNest(flat: flat(excluding: dragged), targetId: targetId,
                              subtreeHeight: vm.subtreeHeight(of: dragged), maxDepth: kMaxFolderDepth)
    }

    private func performMove(_ dragged: UUID, _ target: UUID, _ zone: DropZone) {
        let f = flat(excluding: dragged)
        guard let res = FolderReorder.resolve(flat: f, targetId: target, zone: zone) else { return }
        Task { busy = true; _ = await vm.moveFolder(id: dragged, toParent: res.parentId, index: res.index); busy = false }
    }
}

// 행 높이 수집 — 드롭 시 로컬 y를 비율로 환산할 때 사용.
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
