import SwiftUI

// 메모 목록(홈). 지금은 정적 샘플 — 다음 단계에서 Supabase 연동/Realtime로 교체.
struct MemoListView: View {
    @State private var showCompose = false
    @State private var selectedFilter = "전체"

    private let filters = ["전체", "개발", "신앙", "재테크"]
    private let samples: [SampleMemo] = [
        .init(title: "새 회의 아이디어 정리",
              preview: "다음 스프린트 범위랑 우선순위 다시 잡기. 관련 지표도 같이 확인.",
              meta: nil, classifying: true),
        .init(title: "결제 모듈 반올림 버그",
              preview: "총액이 1원씩 안 맞는다. 라운딩 처리 확인 필요.",
              meta: "개발 · 2시간 전", classifying: false),
        .init(title: "회개 설교 아이디어",
              preview: "웨일즈 부흥에서 회개가 어떻게 시작됐는지 메모.",
              meta: "신앙 · 어제", classifying: false),
        .init(title: "손절 라인 원칙",
              preview: "라인 정하고 기계적으로 매도. 감정은 배제.",
              meta: "재테크 · 3일 전", classifying: false),
    ]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AppColor.bgCanvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    Text("메모").font(.appLargeTitle).foregroundStyle(AppColor.textPrimary)
                        .padding(.top, Space.x2)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.x2) {
                            ForEach(filters, id: \.self) { f in
                                CategoryChip(label: f, selected: f == selectedFilter)
                                    .onTapGesture { selectedFilter = f }
                            }
                        }
                    }

                    ForEach(samples) { m in
                        MemoCardView(title: m.title, preview: m.preview,
                                     meta: m.meta, classifying: m.classifying)
                    }
                }
                .padding(.horizontal, Space.x5)
                .padding(.bottom, 100)
            }

            // FAB
            Button {
                showCompose = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(AppColor.onAccent)
                    .frame(width: 56, height: 56)
                    .background(AppColor.accent)
                    .clipShape(Circle())
            }
            .padding(Space.x5)
        }
        .sheet(isPresented: $showCompose) {
            ComposeView()
        }
    }
}

private struct SampleMemo: Identifiable {
    let id = UUID()
    let title: String
    let preview: String
    let meta: String?
    let classifying: Bool
}

#Preview { MemoListView() }
