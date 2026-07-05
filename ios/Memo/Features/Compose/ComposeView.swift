import SwiftUI

// 메모 작성. 정직한 async: 작성 화면선 분류 결과 안 보여주고, 저장 후 목록에서 "분류 중…"→칩.
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var body_ = ""

    private var canSave: Bool {
        !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColor.bgCanvas.ignoresSafeArea()
                VStack(spacing: Space.x3) {
                    TextField("제목", text: $title)
                        .font(.appBody)
                        .padding(Space.x4)
                        .frame(height: 52)
                        .background(AppColor.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

                    TextEditor(text: $body_)
                        .font(.appBody)
                        .scrollContentBackground(.hidden)
                        .padding(Space.x3)
                        .frame(maxHeight: .infinity)
                        .background(AppColor.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if body_.isEmpty {
                                Text("메모를 입력하세요…")
                                    .font(.appBody).foregroundStyle(AppColor.textTertiary)
                                    .padding(.horizontal, Space.x4).padding(.vertical, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                    // AI 사전 힌트(분류 결과는 저장 후 목록에서)
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
            .navigationTitle("새 메모")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .foregroundStyle(AppColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .foregroundStyle(AppColor.accent)
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        // TODO: 다음 단계 — Supabase INSERT(로컬 우선). 저장 후 목록에서 분류 반영.
        dismiss()
    }
}

#Preview { ComposeView() }
