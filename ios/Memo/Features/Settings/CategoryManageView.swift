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

    // 드래그 재정렬 상태
    @State private var draggingId: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]   // "tree" 좌표계 기준 행 프레임
    @State private var dropGapIndex = 0                  // 현재 삽입 갭(0...행수)
    @State private var dropDepth = 1                     // 현재 목표 뎁스(1-based)

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
                    Text("폴더를 꾹 눌러 위아래로 끌면 순서가, 좌우로 끌면 뎁스가 바뀌어요(삽입선 참고). 다른 폴더 안/최상위로도 옮길 수 있어요. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 비어 있는 폴더만, 최대 3단계까지.")
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

    // 삽입선 — 목표 갭 y에 가로선, dropDepth만큼 들여쓰기.
    @ViewBuilder private var insertionLine: some View {
        if draggingId != nil {
            let flat = flatExcludingDragged()
            Capsule().fill(AppColor.accent).frame(height: 3)
                .padding(.leading, dragBaseX + CGFloat(dropDepth - 1) * dragIndentUnit)
                .padding(.trailing, Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: gapY(flat: flat) - 1.5)
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
        .background(Color.clear, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
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
                    updateDrop(fingerX: drag.location.x, fingerY: drag.location.y)
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

    private func updateDrop(fingerX: CGFloat, fingerY: CGFloat) {
        guard let dragging = draggingId else { return }
        let flat = flatExcludingDragged()
        var gap = flat.count
        for (i, ff) in flat.enumerated() {
            if let r = rowFrames[ff.id], fingerY < r.midY { gap = i; break }
        }
        let rawDepth = Int(((fingerX - dragBaseX) / dragIndentUnit).rounded()) + 1
        let sub = vm.subtreeHeight(of: dragging)
        let range = FolderReorder.depthRange(flat: flat, gapIndex: gap,
                                             subtreeHeight: sub, maxDepth: kMaxFolderDepth)
        dropGapIndex = gap
        dropDepth = min(max(rawDepth, range.lowerBound), range.upperBound)
    }

    private func commitDrop() {
        guard let dragging = draggingId else { return }
        let flat = flatExcludingDragged()
        let res = FolderReorder.resolve(flat: flat, gapIndex: dropGapIndex, depth: dropDepth)
        draggingId = nil
        Task { busy = true; _ = await vm.moveFolder(id: dragging, toParent: res.parentId, index: res.index); busy = false }
    }

    // 삽입 갭의 y(= 위 행 maxY와 아래 행 minY 중간, 끝/처음은 경계).
    private func gapY(flat: [FlatFolder]) -> CGFloat {
        guard !flat.isEmpty else { return 0 }
        if dropGapIndex <= 0 { return rowFrames[flat[0].id]?.minY ?? 0 }
        if dropGapIndex >= flat.count { return rowFrames[flat[flat.count - 1].id]?.maxY ?? 0 }
        let above = rowFrames[flat[dropGapIndex - 1].id]?.maxY ?? 0
        let below = rowFrames[flat[dropGapIndex].id]?.minY ?? 0
        return (above + below) / 2
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
