import SwiftUI

// 폴더 선택 시트 — 폴더 트리에서 택1 또는 미분류. 폴더 생성은 설정의 "폴더 관리"에서.
struct FolderPickerView: View {
    let tree: [FolderNode]   // vm.orderedTree()
    let current: UUID?
    let onSelect: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [FolderNode] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tree }
        // 검색 시엔 들여쓰기 의미가 흐려지므로 depth 0로 평탄화.
        return tree.filter { $0.folder.title.localizedCaseInsensitiveContains(q) }
            .map { FolderNode(folder: $0.folder, depth: 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 미분류(폴더 지정 해제)
                    Button { onSelect(nil); dismiss() } label: {
                        HStack {
                            Text("미분류").foregroundStyle(AppColor.textSecondary)
                            Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(AppColor.accent) }
                        }
                    }
                    ForEach(filtered, id: \.folder.id) { row in
                        Button { onSelect(row.folder.id); dismiss() } label: {
                            HStack {
                                if row.depth > 0 {
                                    Spacer().frame(width: CGFloat(row.depth) * 16)
                                }
                                Text(row.folder.title).foregroundStyle(AppColor.textPrimary)
                                Spacer()
                                if row.folder.id == current {
                                    Image(systemName: "checkmark").foregroundStyle(AppColor.accent)
                                }
                            }
                        }
                    }
                } footer: {
                    if tree.isEmpty {
                        Text("아직 폴더가 없어요. 설정 → 폴더 관리에서 폴더를 만들 수 있어요.")
                    }
                }
            }
            .searchable(text: $search, prompt: "폴더 검색")
            .navigationTitle("폴더 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}
