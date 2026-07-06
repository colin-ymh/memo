import SwiftUI

struct MemoListView: View {
    let auth: AuthService
    @State private var vm = MemoListViewModel()
    @State private var net = NetworkMonitor()
    @State private var showCompose = false
    @State private var showSettings = false

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

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.x2) {
                            // "전체" + 사용순 카테고리. 많으면 상위 N개만 + "더보기"로 접기.
                            let catChips = Array(vm.chips.dropFirst())   // 카테고리(사용순)
                            let limit = 8
                            let showAll = vm.chipsExpanded || catChips.count <= limit
                            let visible = showAll ? catChips : Array(catChips.prefix(limit))

                            CategoryChip(label: "전체", selected: vm.selectedFilter == "전체")
                                .onTapGesture { vm.selectFilter("전체") }
                            ForEach(visible, id: \.self) { f in
                                CategoryChip(label: f, selected: f == vm.selectedFilter)
                                    .onTapGesture { vm.selectFilter(f) }
                            }
                            if catChips.count > limit {
                                CategoryChip(label: showAll ? "접기" : "더보기 \(catChips.count - limit)",
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
                            NavigationLink(value: c.memo) {
                                MemoCardView(title: c.title, preview: c.preview,
                                             meta: c.meta, classifying: c.classifying)
                            }
                            .buttonStyle(.plain)
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
