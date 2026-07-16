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
// 드래그: 순수 SwiftUI 제스처(LongPress→Drag). 이 시트에선 UIKit 기반 drag-drop
// (.draggable/.onDrop)이 안 붙어서 커스텀 제스처 + "tree" 좌표계 히트테스트로 처리.
struct FolderManageView: View {
    @Bindable var vm: MemoListViewModel

    @State private var editor: FolderEditorMode?
    @State private var busy = false

    // 드래그 상태
    @State private var draggingId: UUID?
    @State private var rowFrames: [UUID: CGRect] = [:]   // "tree" 좌표계 행 프레임
    @State private var rootRowFrame: CGRect = .zero       // "전체" 드롭행 프레임
    @State private var dropTargetId: UUID?               // 대상 폴더 행
    @State private var dropZone: DropZone = .after
    @State private var dropIsRoot = false                // 현재 "전체" 위

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
                    Text("폴더를 꾹 눌러 끌면 위/아래=순서·형제, 가운데=그 안으로. 맨 위 ‘전체’에 놓으면 최상위로. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 빈 폴더만, 최대 3단계.")
                        .font(.appCaption).foregroundStyle(AppColor.textTertiary)
                        .padding(.horizontal, Space.x2).padding(.top, Space.x4)
                }
            }
            .padding(Space.x3)
            .coordinateSpace(name: "tree")
            .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
            .overlay(alignment: .top) { insertionLine }
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

    // 최상위(전체)로 빼내는 드롭행.
    private var rootDropRow: some View {
        HStack(spacing: Space.x2) {
            Image(systemName: "tray.full").font(.system(size: 14)).foregroundStyle(AppColor.textSecondary)
            Text("전체 (최상위)").foregroundStyle(AppColor.textSecondary)
            Spacer()
        }
        .padding(.vertical, Space.x3).padding(.horizontal, Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((draggingId != nil && dropIsRoot) ? AppColor.accent.opacity(0.18) : AppColor.fieldBg.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .background(GeometryReader { g in
            Color.clear.preference(key: RootFrameKey.self, value: g.frame(in: .named("tree")))
        })
        .onPreferenceChange(RootFrameKey.self) { rootRowFrame = $0 }
    }

    private func rowView(_ f: Folder, depth: Int) -> some View {
        let isTarget = draggingId != nil && dropTargetId == f.id
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
        .background((isTarget && dropZone == .into) ? AppColor.accent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .background(GeometryReader { g in
            Color.clear.preference(key: RowFrameKey.self, value: [f.id: g.frame(in: .named("tree"))])
        })
        .opacity(draggingId == f.id ? 0.35 : 1)
        .contentShape(Rectangle())
        .gesture(dragGesture(for: f.id))
    }

    // 삽입선 — 인접 두 행 "사이 갭 중앙"에 그린다. 그래서 '일상 아래'와 '가챠맵 위'처럼
    // 결과가 같은 위치는 선도 정확히 같은 자리에 뜬다(존이 바뀌어도 안 점프).
    @ViewBuilder private var insertionLine: some View {
        if draggingId != nil, !dropIsRoot, dropZone != .into,
           let tid = dropTargetId, let r = rowFrames[tid] {
            let g = insertionGeometry(tid: tid, r: r)
            Capsule().fill(AppColor.accent).frame(height: 3)
                .padding(.leading, Space.x3 + CGFloat(g.depth) * indentUnit)
                .padding(.trailing, Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: g.y - 1.5)
                .allowsHitTesting(false)
        }
    }

    // 삽입선 y(갭 중앙)와 들여쓰기 뎁스 계산.
    private func insertionGeometry(tid: UUID, r: CGRect) -> (y: CGFloat, depth: Int) {
        let tree = vm.orderedTree()
        let idx = tree.firstIndex { $0.folder.id == tid } ?? 0
        let hasChildren = vm.childCount(tid) > 0
        let depth = (dropZone == .after && hasChildren) ? tree[idx].depth + 1 : tree[idx].depth
        let y: CGFloat
        if dropZone == .after && hasChildren {
            y = r.maxY
        } else if dropZone == .before {
            let aboveMaxY = idx > 0 ? rowFrames[tree[idx - 1].folder.id]?.maxY : nil
            y = aboveMaxY.map { ($0 + r.minY) / 2 } ?? r.minY
        } else {
            let belowMinY = idx < tree.count - 1 ? rowFrames[tree[idx + 1].folder.id]?.minY : nil
            y = belowMinY.map { (r.maxY + $0) / 2 } ?? r.maxY
        }
        return (y, depth)
    }

    private func dragGesture(for id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(coordinateSpace: .named("tree")))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    if draggingId == nil { draggingId = id }
                    updateDrop(fingerY: drag.location.y)
                }
            }
            .onEnded { _ in commitDrop() }
    }

    // 세로 위치로 대상+구역 결정. 먼저 "전체" 행, 아니면 폴더 행.
    private func updateDrop(fingerY: CGFloat) {
        guard let dragging = draggingId else { return }
        // 전체 행 위?
        if rootRowFrame.height > 0, fingerY >= rootRowFrame.minY, fingerY <= rootRowFrame.maxY {
            dropIsRoot = true; dropTargetId = nil; return
        }
        dropIsRoot = false
        for node in flat(excluding: dragging) {
            guard let r = rowFrames[node.id], fingerY >= r.minY, fingerY <= r.maxY else { continue }
            let rel = r.height > 0 ? (fingerY - r.minY) / r.height : 0.5
            dropTargetId = node.id
            dropZone = rel < 0.25 ? .before
                : (rel > 0.75 ? .after
                   : (canNestOnto(node.id, dragged: dragging) ? .into : .after))
            return
        }
        dropTargetId = nil
    }

    private func commitDrop() {
        guard let dragging = draggingId else { return }
        let target = dropTargetId; let isRoot = dropIsRoot; let zone = dropZone
        draggingId = nil; dropTargetId = nil; dropIsRoot = false
        if isRoot {
            let rootCount = vm.subfolders(of: nil).filter { $0.id != dragging }.count
            Task { busy = true; _ = await vm.moveFolder(id: dragging, toParent: nil, index: rootCount); busy = false }
            return
        }
        guard let t = target else { return }
        let f = flat(excluding: dragging)
        guard let res = FolderReorder.resolve(flat: f, targetId: t, zone: zone) else { return }
        Task { busy = true; _ = await vm.moveFolder(id: dragging, toParent: res.parentId, index: res.index); busy = false }
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
}

private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
private struct RootFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
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
