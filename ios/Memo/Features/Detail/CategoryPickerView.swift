import SwiftUI

// 카테고리 선택/변경 시트 — 기존 카테고리 택1, 미분류, 또는 새로 만들기.
struct CategoryPickerView: View {
    let categories: [Category]
    let current: UUID?
    let onSelect: (UUID?) -> Void
    let onCreate: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var search = ""

    // 지정 화면이라 숨기지 않고 전량 유지 — 대신 검색으로 좁힌다.
    private var filtered: [Category] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return categories }
        return categories.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { c in
                        Button { onSelect(c.id); dismiss() } label: {
                            HStack {
                                Text(c.name).foregroundStyle(AppColor.textPrimary)
                                Spacer()
                                if c.id == current { Image(systemName: "checkmark").foregroundStyle(AppColor.accent) }
                            }
                        }
                    }
                    Button { onSelect(nil); dismiss() } label: {
                        HStack {
                            Text("미분류").foregroundStyle(AppColor.textSecondary)
                            Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(AppColor.accent) }
                        }
                    }
                }
                Section("새 카테고리") {
                    HStack {
                        TextField("이름", text: $newName)
                        Button("추가") {
                            let n = newName; newName = ""
                            Task { await onCreate(n); dismiss() }
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .searchable(text: $search, prompt: "카테고리 검색")
            .navigationTitle("카테고리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}
