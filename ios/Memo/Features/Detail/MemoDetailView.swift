import SwiftUI

// 메모 상세 — 본문 + 카테고리 + 관련 메모(recall).
struct MemoDetailView: View {
    let vm: MemoListViewModel
    let memo: Memo

    @State private var related: [RelatedMemo] = []
    @State private var loadingRelated = true
    @State private var categoryId: UUID?
    @State private var showPicker = false

    init(vm: MemoListViewModel, memo: Memo) {
        self.vm = vm
        self.memo = memo
        _categoryId = State(initialValue: memo.categoryId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x4) {
                Button { showPicker = true } label: {
                    CategoryChip(label: vm.categoryName(categoryId) ?? "＋ 카테고리",
                                 selected: categoryId != nil)
                }
                .buttonStyle(.plain)
                Text(memo.title).font(.appTitle).foregroundStyle(AppColor.textPrimary)
                Text(memo.preview.isEmpty ? memo.content : memo.preview)
                    .font(.appBody).foregroundStyle(AppColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(AppColor.borderDefault)

                Text("관련 메모").font(.appHeadline).foregroundStyle(AppColor.textPrimary)

                if !memo.isClassified {
                    HStack(spacing: Space.x2) {
                        DotSpinner(size: 16)
                        Text("분류 중… 관련 메모는 분류 후 표시돼요")
                            .font(.appCaption).foregroundStyle(AppColor.textTertiary)
                    }
                } else if loadingRelated {
                    HStack(spacing: Space.x2) {
                        DotSpinner(size: 16)
                        Text("관련 메모 찾는 중…")
                            .font(.appCaption).foregroundStyle(AppColor.textTertiary)
                    }
                } else if related.isEmpty {
                    Text("아직 연결된 메모가 없어요")
                        .font(.appSubhead).foregroundStyle(AppColor.textSecondary)
                } else {
                    ForEach(related) { rel in
                        relatedRow(rel)
                    }
                }
            }
            .padding(Space.x5)
        }
        .background(AppColor.bgCanvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: memo.id) {
            guard memo.isClassified else { loadingRelated = false; return }
            loadingRelated = true
            related = (try? await vm.repo.relatedMemos(memoId: memo.id)) ?? []
            loadingRelated = false
        }
        .sheet(isPresented: $showPicker) {
            CategoryPickerView(
                categories: vm.allCategories,
                current: categoryId,
                onSelect: { cid in
                    categoryId = cid
                    Task { await vm.changeCategory(memoId: memo.id, to: cid) }
                },
                onCreate: { name in
                    if let c = await vm.addCategory(name) {
                        categoryId = c.id
                        await vm.changeCategory(memoId: memo.id, to: c.id)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private func relatedRow(_ rel: RelatedMemo) -> some View {
        let card = VStack(alignment: .leading, spacing: 4) {
            Text(rel.title).font(.appSubhead).foregroundStyle(AppColor.textPrimary).lineLimit(1)
            if !rel.snippet.isEmpty {
                Text(rel.snippet).font(.appCaption).foregroundStyle(AppColor.textSecondary).lineLimit(1)
            }
            let cat = vm.categoryName(rel.categoryId)
            Text("\(cat.map { "\($0) · " } ?? "")유사도 \(String(format: "%.2f", rel.similarity))")
                .font(.appFootnote).foregroundStyle(AppColor.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.x4)
        .background(AppColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

        if let target = vm.memo(rel.id) {
            NavigationLink(value: target) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }
}
