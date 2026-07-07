import SwiftUI

struct MemoListView: View {
    let auth: AuthService
    @State private var vm = MemoListViewModel()
    @State private var net = NetworkMonitor()
    @State private var showCompose = false
    @State private var showSettings = false
    @State private var editingMemo: Memo?         // 스와이프 편집 시트 대상
    @State private var pendingDeleteID: UUID?     // 스와이프 삭제 확인 대상
    @State private var searchCollapsed = false     // 스크롤 내림 시 검색창 접힘
    @State private var lastOffset: CGFloat = 0

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

            VStack(spacing: 0) {
                fixedHeader
                listOrEmpty
            }

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
            ComposeView { content in await vm.create(content: content) }
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

    // 스크롤 밖 고정 헤더: 제목 · 검색(접힘) · 카테고리 칩 · 오프라인 배너
    private var fixedHeader: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            HStack(alignment: .firstTextBaseline) {
                Text("메모").font(.appLargeTitle).foregroundStyle(AppColor.textPrimary)
                Spacer()
                Menu {
                    Picker("정렬", selection: $vm.sortOrder) {
                        ForEach(MemoSort.allCases) { s in Text(s.label).tag(s) }
                    }
                    Toggle("미분류만", isOn: $vm.uncategorizedOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 20)).foregroundStyle(AppColor.textSecondary)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20)).foregroundStyle(AppColor.textSecondary)
                }
            }
            .padding(.top, Space.x2)

            if !searchCollapsed {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            chipsBar

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
        }
        .padding(.horizontal, Space.x5)
        .padding(.bottom, Space.x2)
    }

    // 검색. 본문(로컬 즉시) / 의미(시맨틱, 제출 시 서버) 모드 토글.
    private var searchField: some View {
        HStack(spacing: Space.x2) {
            if vm.searching {
                DotSpinner(size: 18)
            } else {
                Image(systemName: vm.semanticMode ? "sparkle.magnifyingglass" : "magnifyingglass")
                    .foregroundStyle(AppColor.textTertiary)
            }
            TextField(vm.semanticMode ? "의미로 검색 (엔터)" : "메모 검색", text: $vm.searchText)
                .foregroundStyle(AppColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { if vm.semanticMode { Task { await vm.runSemanticSearch() } } }
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppColor.textTertiary)
                }
            }
            Button { vm.semanticMode.toggle() } label: {
                Image(systemName: "sparkles")
                    .foregroundStyle(vm.semanticMode ? AppColor.accent : AppColor.textTertiary)
            }
        }
        .padding(.horizontal, Space.x3).padding(.vertical, Space.x3)
        .background(AppColor.fieldBg)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.x2) {
                let catChips = Array(vm.chips.dropFirst())   // 카테고리(사용순)
                let limit = 8
                let showAll = vm.chipsExpanded || catChips.count <= limit
                let visible = showAll ? catChips : Array(catChips.prefix(limit))

                CategoryChip(label: String(localized: "전체"), selected: vm.selectedFilter == "전체")
                    .onTapGesture { vm.selectFilter("전체") }
                ForEach(visible, id: \.self) { f in
                    CategoryChip(label: f, selected: f == vm.selectedFilter)
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
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if vm.cards.isEmpty && !vm.isLoading {
            emptyState
            Spacer(minLength: 0)
        } else {
            List {
                ForEach(vm.cards) { c in
                    MemoCardView(title: c.title, preview: c.preview,
                                 meta: c.meta, classifying: c.classifying, pinned: c.pinned)
                        .contentShape(Rectangle())
                        .background(NavigationLink(value: c.memo) { EmptyView() }.opacity(0))
                        // 스크롤 관찰기(카드 배경, 별도 행 안 만들어 간격 유발 방지) — 접힘 방향 감지
                        .background(ScrollOffsetReader { y in Task { @MainActor in handleScroll(y) } })
                        .listRowInsets(EdgeInsets(top: Space.x2, leading: Space.x5,
                                                  bottom: Space.x2, trailing: Space.x5))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDeleteID = c.id } label: {
                                Label("삭제", systemImage: "trash")
                            }
                            Button { editingMemo = c.memo } label: {
                                Label("편집", systemImage: "pencil")
                            }.tint(AppColor.accent)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await vm.togglePin(memoId: c.id) }
                            } label: {
                                Label(c.pinned ? "고정 해제" : "고정",
                                      systemImage: c.pinned ? "pin.slash" : "pin")
                            }.tint(AppColor.accent)
                        }
                }

                if let err = vm.errorText {
                    Text(err).font(.appCaption).foregroundStyle(AppColor.danger)
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)   // List 기본 상단 inset 제거(간격 축소)
            .refreshable { await vm.load() }
        }
    }

    // 스크롤 방향으로 검색창 접힘/펼침. y=contentOffset.y(최상단 0, 내리면 증가).
    @MainActor private func handleScroll(_ y: CGFloat) {
        let delta = y - lastOffset
        lastOffset = y
        // 상단 존(y<60): 항상 표시 → 짧은 플릭이 "사라지다 말기" 방지(부분 애니 안 생김).
        if y < 60 {
            setSearchCollapsed(false)
        } else if delta > 6 {                          // 충분히 아래로 → 숨김
            setSearchCollapsed(true)
        } else if delta < -16 {                        // 뚜렷이 위로 → 표시(바운스 지터 컷)
            setSearchCollapsed(false)
        }
    }

    // 상태 바뀔 때만 애니(진행 중 애니 재시작·중단으로 인한 부분표시 방지).
    @MainActor private func setSearchCollapsed(_ v: Bool) {
        guard searchCollapsed != v else { return }
        withAnimation(.easeInOut(duration: 0.22)) { searchCollapsed = v }
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
