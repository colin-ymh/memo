import SwiftUI

struct MemoListView: View {
    let auth: AuthService
    @State private var vm = MemoListViewModel()
    @State private var net = NetworkMonitor()
    @State private var showCompose = false
    @State private var showSettings = false
    @State private var openRowID: UUID?          // 스와이프로 열린 행(한 번에 하나)
    @State private var editingMemo: Memo?         // 스와이프 편집 시트 대상
    @State private var pendingDeleteID: UUID?     // 스와이프 삭제 확인 대상

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(for: Memo.self) { m in
                    MemoDetailView(vm: vm, memo: m)
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        ZStack(alignment: .bottomTrailing) {
            AppColor.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("메모").font(.appLargeTitle).foregroundStyle(AppColor.textPrimary)
                        Spacer()
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20))
                                .foregroundStyle(AppColor.textSecondary)
                        }
                    }
                    .padding(.top, Space.x2)

                    // 메모 본문 검색(로컬 필터). 네비바 숨김 UI라 .searchable 대신 커스텀 필드.
                    HStack(spacing: Space.x2) {
                        Image(systemName: "magnifyingglass").foregroundStyle(AppColor.textTertiary)
                        TextField("메모 검색", text: $vm.searchText)
                            .foregroundStyle(AppColor.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !vm.searchText.isEmpty {
                            Button { vm.searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(AppColor.textTertiary)
                            }
                        }
                    }
                    .padding(.horizontal, Space.x3).padding(.vertical, Space.x3)
                    .background(AppColor.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.x2) {
                            // "전체" + 사용순 카테고리. 많으면 상위 N개만 + "더보기"로 접기.
                            let catChips = Array(vm.chips.dropFirst())   // 카테고리(사용순)
                            let limit = 8
                            let showAll = vm.chipsExpanded || catChips.count <= limit
                            let visible = showAll ? catChips : Array(catChips.prefix(limit))

                            // "전체" sentinel은 로직값 유지, 표시만 번역(CategoryChip은 verbatim).
                            CategoryChip(label: String(localized: "전체"), selected: vm.selectedFilter == "전체")
                                .onTapGesture { vm.selectFilter("전체") }
                            ForEach(visible, id: \.self) { f in
                                CategoryChip(label: f, selected: f == vm.selectedFilter)   // 카테고리명=데이터, 번역 안 함
                                    .onTapGesture { vm.selectFilter(f) }
                            }
                            if catChips.count > limit {
                                CategoryChip(label: showAll ? String(localized: "접기")
                                                             : String(localized: "더보기 \(catChips.count - limit)"),
                                             selected: false)
                                    .onTapGesture { vm.chipsExpanded.toggle() }
                            }
                        }
                    }

                    if vm.offline {
                        HStack(spacing: Space.x2) {
                            Image(systemName: "wifi.slash")
                            Text("오프라인 · 저장된 메모 표시 중")
                        }
                        .font(.appCaption).foregroundStyle(AppColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.x3)
                        .background(AppColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    }

                    if vm.cards.isEmpty && !vm.isLoading {
                        emptyState
                    } else {
                        ForEach(vm.cards) { c in
                            SwipeableRow(rowID: c.id, openRowID: $openRowID,
                                         onEdit: { editingMemo = c.memo },
                                         onDelete: { pendingDeleteID = c.id }) {
                                NavigationLink(value: c.memo) {
                                    MemoCardView(title: c.title, preview: c.preview,
                                                 meta: c.meta, classifying: c.classifying)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let err = vm.errorText {
                        Text(err).font(.appCaption).foregroundStyle(AppColor.danger)
                    }
                }
                .padding(.horizontal, Space.x5)
                .padding(.bottom, 100)
            }
            .refreshable { await vm.load() }

            Button { showCompose = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(width: 56, height: 56)
                    .background(AppColor.accent)
                    .clipShape(Circle())
            }
            .padding(Space.x5)
        }
        .task {
            net.onReconnect = { Task { await vm.flush() } }
            net.start()
            await vm.load()
            await vm.startRealtime()
        }
        .sheet(isPresented: $showCompose) {
            ComposeView { content in
                await vm.create(content: content)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(auth: auth, vm: vm)
        }
        // 스와이프 편집 — ComposeView 프리필(상세 편집과 동일 패턴)
        .sheet(item: $editingMemo) { m in
            ComposeView(initialContent: m.content, navTitle: "메모 편집") { newContent in
                await vm.updateMemo(memoId: m.id, content: newContent)
            }
        }
        // 스와이프 삭제 확인
        .confirmationDialog("이 메모를 삭제할까요?",
                            isPresented: Binding(get: { pendingDeleteID != nil },
                                                 set: { if !$0 { pendingDeleteID = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let id = pendingDeleteID { Task { await vm.deleteMemo(id) } }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.x3) {
            Text("아직 메모가 없어요")
                .font(.appHeadline).foregroundStyle(AppColor.textPrimary)
            Text("＋ 를 눌러 첫 메모를 남겨보세요")
                .font(.appSubhead).foregroundStyle(AppColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 80)
    }
}
