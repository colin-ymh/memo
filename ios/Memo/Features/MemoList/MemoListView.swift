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
    @State private var path = NavigationPath()
    @State private var drawerOpen = false           // 좌측 폴더 드로어
    @State private var dragOffset: CGFloat = 0       // 드로어 스와이프 중 offset
    private let drawerWidth: CGFloat = 300

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Memo.self) { m in
                    MemoDetailView(vm: vm, memo: m)
                }
                .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var content: some View {
        ZStack(alignment: .leading) {
            mainStack

            // 드로어 열림 시 배경 딤(탭하면 닫힘)
            if drawerOpen {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }
            }

            FolderDrawerView(vm: vm, width: drawerWidth) { closeDrawer() }
                .frame(width: drawerWidth)
                .frame(maxHeight: .infinity)
                .background(AppColor.bgSurface)
                .offset(x: currentDrawerX)
                .ignoresSafeArea(edges: .vertical)
        }
        .gesture(edgeSwipe)
        .task {
            net.onReconnect = { Task { await vm.flush() } }
            net.start()
            await vm.load()
            await vm.startRealtime()
        }
        .sheet(isPresented: $showCompose) {
            // 폴더 안에서 작성하면 그 폴더로 바로 저장(기본값). 전체/미분류에선 AI 자동.
            ComposeView(folderTree: vm.orderedTree(), initialFolderId: vm.currentFolderId) { content, folderId in
                await vm.create(content: content, folderId: folderId)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(auth: auth, vm: vm)
        }
        // 스와이프 편집 — ComposeView 프리필(상세 편집과 동일 패턴)
        .sheet(item: $editingMemo) { m in
            ComposeView(initialContent: m.content, navTitle: "메모 편집") { newContent, _ in
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

    // 메인(목록 + FAB). 드로어는 이 위에 오버레이.
    private var mainStack: some View {
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
    }

    // 드로어 현재 x 위치. 닫힘=-width, 열림=0, 스와이프 중=드래그 반영.
    private var currentDrawerX: CGFloat {
        let base = drawerOpen ? 0 : -drawerWidth
        return max(-drawerWidth, min(0, base + dragOffset))
    }

    private func openDrawer()  { withAnimation(.easeOut(duration: 0.25)) { drawerOpen = true }; dragOffset = 0 }
    private func closeDrawer() { withAnimation(.easeOut(duration: 0.25)) { drawerOpen = false }; dragOffset = 0 }

    // 좌측 엣지 스와이프로 열기 / 드로어 열린 상태서 왼쪽으로 밀어 닫기.
    private var edgeSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                if drawerOpen {
                    dragOffset = min(0, g.translation.width)          // 왼쪽으로만
                } else if g.startLocation.x < 24, g.translation.width > 0 {
                    dragOffset = min(drawerWidth, g.translation.width) // 엣지서 오른쪽으로
                }
            }
            .onEnded { g in
                if drawerOpen {
                    if g.translation.width < -60 { closeDrawer() } else { withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 } }
                } else if g.startLocation.x < 24, g.translation.width > 60 {
                    openDrawer()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                }
            }
    }

    // 스크롤 밖 고정 헤더: 제목 · 검색(접힘) · 폴더 위치 · 오프라인 배너
    private var fixedHeader: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            HStack(alignment: .center, spacing: Space.x2) {
                // 현재 폴더 제목 = 드로어 여는 버튼(Liquid Glass)
                Button { openDrawer() } label: {
                    HStack(spacing: Space.x2) {
                        Image(systemName: "line.3.horizontal").font(.system(size: 17, weight: .semibold))
                        Text(vm.currentTitle).font(.appLargeTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppColor.textSecondary)
                    }
                    .foregroundStyle(AppColor.textPrimary)
                    .padding(.leading, Space.x4).padding(.trailing, Space.x4)
                    .padding(.vertical, Space.x2)
                    .glassBg(Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: Space.x1)

                Menu {
                    Picker("정렬", selection: $vm.sortOrder) {
                        ForEach(MemoSort.allCases) { s in Text(s.label).tag(s) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(AppColor.textPrimary)
                        .frame(width: 44, height: 44).glassBg(Circle())
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(AppColor.textPrimary)
                        .frame(width: 44, height: 44).glassBg(Circle())
                }
            }
            .padding(.top, Space.x2)

            if !searchCollapsed {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
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


    @ViewBuilder
    private var listOrEmpty: some View {
        if vm.cards.isEmpty && !vm.isLoading {
            emptyState
            Spacer(minLength: 0)
        } else {
            List {
                ForEach(vm.cards) { c in
                    // List에선 배경 NavigationLink가 탭 처리 안 됨 → Button+path로 이동(셰브론 없음, 탭 확실).
                    Button { path.append(c.memo) } label: {
                        MemoCardView(title: c.title, preview: c.preview,
                                     meta: c.meta, classifying: c.classifying, pinned: c.pinned)
                    }
                    .buttonStyle(.plain)
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

// 좌측 폴더 드로어 — 전체 · 폴더 트리(위계) · 미분류. 선택 시 목록 필터 + 닫힘.
struct FolderDrawerView: View {
    let vm: MemoListViewModel
    let width: CGFloat
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("폴더").font(.appTitle).foregroundStyle(AppColor.textPrimary)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppColor.textTertiary)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, Space.x4).padding(.top, 72).padding(.bottom, Space.x4)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x1) {
                    row(title: String(localized: "전체"), icon: "tray.full", depth: 0, count: nil,
                        selected: vm.currentFolderId == nil && !vm.unclassifiedMode) {
                        vm.goToRoot(); onClose()
                    }
                    ForEach(vm.orderedTree()) { node in
                        row(title: node.folder.title, icon: "folder", depth: node.depth,
                            count: vm.memoCount(node.folder.id),
                            selected: vm.currentFolderId == node.folder.id && !vm.unclassifiedMode) {
                            vm.enterFolder(node.folder.id); onClose()
                        }
                    }
                    Divider().overlay(AppColor.borderDefault).padding(.vertical, Space.x3)
                    row(title: String(localized: "미분류"), icon: "tray", depth: 0, count: nil,
                        selected: vm.unclassifiedMode) {
                        vm.enterUnclassified(); onClose()
                    }
                }
                .padding(.horizontal, Space.x3).padding(.bottom, Space.x10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(title: String, icon: String, depth: Int, count: Int?,
                     selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.x3) {
                if depth > 0 { Spacer().frame(width: CGFloat(depth) * 20) }
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24)
                    .foregroundStyle(selected ? AppColor.accent : AppColor.textSecondary)
                Text(title).font(.appBody).lineLimit(1)
                    .foregroundStyle(selected ? AppColor.accent : AppColor.textPrimary)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)").font(.appSubhead).foregroundStyle(AppColor.textTertiary)
                }
            }
            .padding(.vertical, Space.x3).padding(.horizontal, Space.x3)
            .background(selected ? AppColor.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Liquid Glass(iOS 26+) — 이하 버전은 은은한 배경으로 폴백.
extension View {
    @ViewBuilder func glassBg(_ shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(AppColor.fieldBg, in: shape)
        }
    }
}
