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
    @State private var reparentTarget: Folder?
    @State private var busy = false

    var body: some View {
        List {
            let tree = vm.orderedTree()
            if tree.isEmpty {
                Text("아직 폴더가 없어요. 오른쪽 위 ＋로 첫 폴더를 만들어보세요.")
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                Section {
                    ForEach(tree, id: \.folder.id) { row in
                        rowView(row.folder, depth: row.depth)
                    }
                } footer: {
                    Text("＋로 하위 폴더 추가, ⋯로 편집·이동·삭제. 삭제는 비어 있는 폴더만 가능하고, 최대 3단계까지 만들 수 있어요.")
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
        // 이동 대상 선택
        .confirmationDialog("어디로 옮길까요?",
                            isPresented: Binding(get: { reparentTarget != nil },
                                                 set: { if !$0 { reparentTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: reparentTarget) { f in
            if f.parentId != nil {
                Button("최상위로 이동") {
                    Task { busy = true; _ = await vm.reparentFolder(id: f.id, to: nil); busy = false }
                }
            }
            ForEach(validParents(for: f)) { p in
                Button("\(vm.folderPath(p.id) ?? p.title) 아래로") {
                    Task { busy = true; _ = await vm.reparentFolder(id: f.id, to: p.id); busy = false }
                }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("깊이가 3단계를 넘거나 순환이 되는 이동은 자동으로 막혀요.")
        }
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
                Button { reparentTarget = f } label: { Label("이동", systemImage: "folder") }
                if vm.canDelete(f.id) {
                    Button(role: .destructive) {
                        Task { busy = true; _ = await vm.deleteFolder(id: f.id); busy = false }
                    } label: { Label("삭제", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 18)).foregroundStyle(AppColor.textSecondary)
            }
        }
    }

    // 이동 후보: 자기 자신·후손 제외, 현재 부모 제외, 부모가 되면 3단계 이내여야(부모 깊이<3).
    private func validParents(for f: Folder) -> [Folder] {
        let desc = vm.descendantIds(of: f.id)
        return vm.allFolders
            .filter { $0.id != f.id && $0.id != f.parentId
                && !desc.contains($0.id) && vm.depth(of: $0.id) < kMaxFolderDepth }
            .sorted { $0.title < $1.title }
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
