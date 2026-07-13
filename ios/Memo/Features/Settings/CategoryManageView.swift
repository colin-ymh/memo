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
    @State private var dropTarget: UUID?          // 폴더 위로 끌 때 하이라이트 대상
    @State private var rootTargeted = false        // 최상위 드롭행 하이라이트
    @State private var busy = false

    var body: some View {
        List {
            let tree = vm.orderedTree()
            if tree.isEmpty {
                Text("아직 폴더가 없어요. 오른쪽 위 ＋로 첫 폴더를 만들어보세요.")
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                Section {
                    rootDropRow
                    ForEach(tree, id: \.folder.id) { row in
                        rowView(row.folder, depth: row.depth)
                    }
                } footer: {
                    Text("폴더를 꾹 눌러 다른 폴더 위로 끌면 그 아래로 옮겨져요. 맨 위 ‘최상위’로 끌면 밖으로 나와요. ＋로 하위 폴더 추가, ⋯로 편집·삭제. 삭제는 비어 있는 폴더만, 최대 3단계까지.")
                }
            }
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

    // 최상위로 꺼내는 드롭 존 — 여기로 끌면 부모 없음(root)으로.
    private var rootDropRow: some View {
        HStack(spacing: Space.x2) {
            Image(systemName: "arrow.up.to.line").font(.system(size: 14)).foregroundStyle(AppColor.textSecondary)
            Text("최상위").foregroundStyle(AppColor.textSecondary)
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(rootTargeted ? AppColor.accent.opacity(0.15) : nil)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let dragged = UUID(uuidString: s),
                  vm.canReparent(id: dragged, to: nil) else { return false }
            Task { busy = true; _ = await vm.reparentFolder(id: dragged, to: nil); busy = false }
            return true
        } isTargeted: { rootTargeted = $0 }
    }

    private func rowView(_ f: Folder, depth: Int) -> some View {
        HStack(spacing: Space.x2) {
            if depth > 0 { Spacer().frame(width: CGFloat(depth) * 16) }
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
            // 편집/이동/삭제 메뉴 — 눈에 보이는 ⋯
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
        .draggable(f.id.uuidString)
        .listRowBackground(dropTarget == f.id ? AppColor.accent.opacity(0.15) : nil)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let dragged = UUID(uuidString: s),
                  vm.canReparent(id: dragged, to: f.id) else { return false }
            Task { busy = true; _ = await vm.reparentFolder(id: dragged, to: f.id); busy = false }
            return true
        } isTargeted: { over in
            dropTarget = over ? f.id : (dropTarget == f.id ? nil : dropTarget)
        }
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
