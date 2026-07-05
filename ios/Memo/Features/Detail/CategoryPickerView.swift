import SwiftUI

// 카테고리 선택/변경 시트 — 기존 카테고리 택1, 미분류, 또는 새로 만들기.
struct CategoryPickerView: View {
    let categories: [Category]
    let current: UUID?
    let onSelect: (UUID?) -> Void
    let onCreate: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(categories) { c in
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
            .navigationTitle("카테고리")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
            }
        }
    }
}
