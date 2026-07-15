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

// 폴더 관리 — 트리 편집. 생성/이름·설명 수정/이동(reparent)/삭제(빈 폴더만).
// 모든 변경은 온라인 즉시 실행 후 vm.load() 반영(오프라인 큐 대상 아님).
struct FolderManageView: View {
    @Bindable var vm: MemoListViewModel

    @State private var editor: FolderEditorMode?
    @State private var busy = false

    // 드래그 재정렬 상태 — 세로만으로 판단(대상 행 + 구역).
    @State private var draggingId: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]   // "tree" 좌표계 기준 행 프레임
    @State private var dropTargetId: UUID?               // 현재 드롭 대상 행
    @State private var dropZone: DropZone = .after       // before=위/into=가운데/after=아래

    // 좌표 상수(rowView 들여쓰기와 정합). Space.x3=12 = 행 좌측 패딩, 16 = depth당 들여쓰기.
    private let dragBaseX: CGFloat = 12
    private let dragIndentUnit: CGFloat = 16

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
                    Text("폴더를 꾹 눌러 위/아래로 끌면 순서가 바뀌고, 폴더 위(가운데)에 놓으면 그 안으로 들어가요. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 비어 있는 폴더만, 최대 3단계까지.")
                        .font(.appCaption).foregroundStyle(AppColor.textTertiary)
                        .padding(.horizontal, Space.x2).padding(.top, Space.x4)
                }
            }
            .coordinateSpace(name: "tree")
            .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
            .overlay(alignment: .top) { insertionLine }
            .padding(Space.x3)
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

    // 삽입선 — before/after일 때만. 대상 행 위/아래 모서리에, 행 뎁스만큼 들여쓰기.
    // (into는 rowView 배경 하이라이트로 표시.)
    @ViewBuilder private var insertionLine: some View {
        if draggingId != nil, dropZone != .into, let tid = dropTargetId, let r = rowFrames[tid] {
            let depth = flatExcludingDragged().first { $0.id == tid }?.depth ?? 1
            let y = (dropZone == .before ? r.minY : r.maxY) - 1.5
            Capsule().fill(AppColor.accent).frame(height: 3)
                .padding(.leading, dragBaseX + CGFloat(depth - 1) * dragIndentUnit)
                .padding(.trailing, Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: y)
                .allowsHitTesting(false)
        }
    }

    private func rowView(_ f: Folder, depth: Int) -> some View {
        HStack(spacing: Space.x2) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * dragIndentUnit) }
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
            // 하위 추가(뎁스 여유 있을 때) — 눈에 보이는 버튼
            if vm.depth(of: f.id) < kMaxFolderDepth {
                Button { editor = .create(parent: f.id) } label: {
                    Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(AppColor.accent)
                }
                .buttonStyle(.plain)
            }
            // 편집/삭제 메뉴 — 눈에 보이는 ⋯
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
        .background((draggingId != nil && dropZone == .into && dropTargetId == f.id)
                        ? AppColor.accent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .opacity(draggingId == f.id ? 0.35 : 1)
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFramesKey.self, value: [f.id: g.frame(in: .named("tree"))])
        })
        .gesture(dragGesture(for: f.id))
    }

    // 롱프레스 후 드래그 — ScrollView 스크롤과 공존.
    private func dragGesture(for id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(coordinateSpace: .named("tree")))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    if draggingId == nil { draggingId = id }
                    updateDrop(fingerY: drag.location.y)
                }
            }
            .onEnded { _ in commitDrop() }
    }

    // 드래그 서브트리를 제외한 평탄 배열(FolderReorder 입력). depth 0-based→1-based(+1).
    private func flatExcludingDragged() -> [FlatFolder] {
        guard let dragging = draggingId else { return [] }
        let excluded = vm.descendantIds(of: dragging).union([dragging])
        return vm.orderedTree()
            .filter { !excluded.contains($0.folder.id) }
            .map { FlatFolder(id: $0.folder.id, parentId: $0.folder.parentId, depth: $0.depth + 1) }
    }

    // 세로 위치만으로 대상 행 + 구역 결정. 행 상단 1/3=before, 하단 1/3=after, 가운데=into.
    // into는 nest 가능할 때만(불가 시 after로 강등).
    private func updateDrop(fingerY: CGFloat) {
        guard let dragging = draggingId else { return }
        let flat = flatExcludingDragged()
        guard !flat.isEmpty else { dropTargetId = nil; return }

        var target: FlatFolder?
        var rel: CGFloat = 0.5
        for ff in flat {
            if let r = rowFrames[ff.id], fingerY >= r.minY, fingerY <= r.maxY {
                target = ff
                rel = r.height > 0 ? (fingerY - r.minY) / r.height : 0.5
                break
            }
        }
        if target == nil {   // 첫 행 위 / 마지막 행 아래
            if let first = flat.first, let r = rowFrames[first.id], fingerY < r.minY {
                target = first; rel = 0
            } else if let last = flat.last {
                target = last; rel = 1
            }
        }
        guard let t = target else { dropTargetId = nil; return }

        var zone: DropZone = rel < 0.33 ? .before : (rel > 0.67 ? .after : .into)
        if zone == .into,
           !FolderReorder.canNest(flat: flat, targetId: t.id,
                                  subtreeHeight: vm.subtreeHeight(of: dragging), maxDepth: kMaxFolderDepth) {
            zone = .after
        }
        dropTargetId = t.id
        dropZone = zone
    }

    private func commitDrop() {
        guard let dragging = draggingId, let target = dropTargetId else { draggingId = nil; return }
        let flat = flatExcludingDragged()
        draggingId = nil
        guard let res = FolderReorder.resolve(flat: flat, targetId: target, zone: dropZone) else { return }
        Task { busy = true; _ = await vm.moveFolder(id: dragging, toParent: res.parentId, index: res.index); busy = false }
    }
}

// 행 프레임 수집(트리 좌표계). 삽입 갭·삽입선 계산용.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
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
