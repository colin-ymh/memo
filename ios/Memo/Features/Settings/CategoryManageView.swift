import SwiftUI

// 카테고리 관리 — 사용순 목록 + 메모 수. 스와이프로 이름변경/병합.
// 병합·이름변경은 온라인 즉시 실행 후 vm.load()로 반영(오프라인 큐 대상 아님).
struct CategoryManageView: View {
    @Bindable var vm: MemoListViewModel

    @State private var renameTarget: Category?
    @State private var renameText = ""
    @State private var mergeSource: Category?
    @State private var busy = false

    var body: some View {
        List {
            if vm.allCategories.isEmpty {
                Text("아직 카테고리가 없어요.")
                    .foregroundStyle(AppColor.textSecondary)
            } else {
                Section {
                    ForEach(vm.allCategories) { c in
                        HStack {
                            Text(c.name).foregroundStyle(AppColor.textPrimary)
                            Spacer()
                            Text("메모 \(vm.categoryCounts[c.id] ?? 0)")
                                .font(.appCaption).foregroundStyle(AppColor.textSecondary)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                mergeSource = c
                            } label: { Label("병합", systemImage: "arrow.triangle.merge") }
                                .tint(AppColor.accent)
                            Button {
                                renameText = c.name; renameTarget = c
                            } label: { Label("이름변경", systemImage: "pencil") }
                        }
                    }
                } footer: {
                    Text("행을 왼쪽으로 밀어 이름을 바꾸거나 다른 카테고리로 병합할 수 있어요.")
                }
            }
        }
        .disabled(busy)
        .navigationTitle("카테고리 관리")
        .navigationBarTitleDisplayMode(.inline)
        // 이름 변경
        .alert("이름 변경", isPresented: Binding(get: { renameTarget != nil },
                                             set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { cat in
            TextField("이름", text: $renameText)
            Button("저장") {
                Task { busy = true; _ = await vm.renameCategory(cat.id, to: renameText); busy = false }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("같은 이름이 이미 있으면 실패해요. 그럴 땐 병합을 쓰세요.")
        }
        // 병합 대상 선택
        .confirmationDialog("어느 카테고리로 병합할까요?",
                            isPresented: Binding(get: { mergeSource != nil },
                                                 set: { if !$0 { mergeSource = nil } }),
                            titleVisibility: .visible,
                            presenting: mergeSource) { src in
            ForEach(vm.allCategories.filter { $0.id != src.id }) { dst in
                Button("\(dst.name)(으)로 병합") {
                    Task { busy = true; _ = await vm.mergeCategory(src.id, into: dst.id); busy = false }
                }
            }
            Button("취소", role: .cancel) {}
        } message: { src in
            Text("\"\(src.name)\"의 메모가 대상으로 옮겨지고 이 카테고리는 삭제됩니다.")
        }
    }
}
