import SwiftUI

// 목록 카드용 커스텀 스와이프 액션(왼쪽으로 밀어 편집/삭제).
// 목록이 List가 아니라 ScrollView라 .swipeActions 못 씀 → DragGesture로 구현.
// 한 번에 한 행만 열림: openRowID 공유 바인딩.
struct SwipeableRow<Content: View>: View {
    let rowID: UUID
    @Binding var openRowID: UUID?
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    private let buttonWidth: CGFloat = 74
    private var actionWidth: CGFloat { buttonWidth * 2 }
    private var isOpen: Bool { openRowID == rowID }

    var body: some View {
        ZStack(alignment: .trailing) {
            // 뒤에 깔리는 액션 버튼(편집/삭제)
            HStack(spacing: 0) {
                actionButton(icon: "pencil", label: "편집",
                             fg: AppColor.onAccent, bg: AppColor.accent) {
                    close(); onEdit()
                }
                actionButton(icon: "trash", label: "삭제",
                             fg: AppColor.onDanger, bg: AppColor.danger) {
                    close(); onDelete()
                }
            }
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))

            // 카드 본체
            content()
                .offset(x: offset)
                .overlay {
                    // 열린 상태서 카드 탭 → 네비게이션 대신 닫기
                    if isOpen {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .highPriorityGesture(drag)
        }
        // 다른 행이 열리면 이 행은 닫힘
        .onChange(of: openRowID) { _, newValue in
            if newValue != rowID, offset != 0 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
            }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                // 수평 우세일 때만 반응(수직은 스크롤에 양보)
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                let base = isOpen ? -actionWidth : 0
                offset = min(max(base + v.translation.width, -actionWidth), 0)
            }
            .onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if offset < -actionWidth / 2 { open() } else { close() }
            }
    }

    private func open() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = -actionWidth }
        openRowID = rowID
    }
    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
        if isOpen { openRowID = nil }
    }

    private func actionButton(icon: String, label: LocalizedStringKey,
                              fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.x1) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(label).font(.appCaption)
            }
            .foregroundStyle(fg)
            .frame(width: buttonWidth)
            .frame(maxHeight: .infinity)
            .background(bg)
        }
        .buttonStyle(.plain)
    }
}
