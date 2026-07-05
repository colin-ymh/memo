import SwiftUI

// 메모 작성. 정직한 async: 작성 화면선 분류 결과 안 보여주고, 저장 후 목록에서 "분류 중…"→칩.
struct ComposeView: View {
    let navTitle: String
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var saving = false

    init(initialContent: String = "", navTitle: String = "새 메모",
         onSave: @escaping (String) async -> Void) {
        self.navTitle = navTitle
        self.onSave = onSave
        let parts = initialContent.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        _title = State(initialValue: parts.first.map(String.init) ?? "")
        _bodyText = State(initialValue: parts.count > 1 ? String(parts[1]) : "")
    }

    private var content: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return [t, b].filter { !$0.isEmpty }.joined(separator: "\n")
    }
    private var canSave: Bool { !content.isEmpty && !saving }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.bgCanvas.ignoresSafeArea()
                VStack(spacing: Space.x3) {
                    TextField("제목", text: $title)
                        .font(.appBody)
                        .padding(Space.x4).frame(height: 52)
                        .background(AppColor.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

                    TextEditor(text: $bodyText)
                        .font(.appBody)
                        .scrollContentBackground(.hidden)
                        .padding(Space.x3)
                        .frame(maxHeight: .infinity)
                        .background(AppColor.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if bodyText.isEmpty {
                                Text("메모를 입력하세요…")
                                    .font(.appBody).foregroundStyle(AppColor.textTertiary)
                                    .padding(.horizontal, Space.x4).padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: Space.x2) {
                        Image(systemName: "tag")
                        Text("저장하면 AI가 자동으로 분류해요")
                    }
                    .font(.appCaption).foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.x4)
                    .background(AppColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .padding(Space.x5)
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }.foregroundStyle(AppColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        saving = true
                        Task {
                            await onSave(content)
                            dismiss()
                        }
                    }
                    .foregroundStyle(AppColor.accent)
                    .disabled(!canSave)
                }
            }
        }
    }
}
