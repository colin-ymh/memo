import SwiftUI

// 카테고리 칩(pill)
struct CategoryChip: View {
    let label: String
    var selected: Bool = false
    var body: some View {
        Text(label)
            .font(.appSubhead)
            .foregroundStyle(selected ? AppColor.onAccent : AppColor.textSecondary)
            .padding(.horizontal, Space.x4)
            .frame(height: 34)
            .background(selected ? AppColor.accent : AppColor.bgSurface)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(AppColor.borderDefault, lineWidth: selected ? 0 : 1)
            )
    }
}

// 8-dot 스피너("분류 중…" 등)
struct DotSpinner: View {
    var size: CGFloat = 16
    @State private var angle: Double = 0
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Circle()
                    .fill(AppColor.textPrimary)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .opacity(0.15 + Double(i) / 8.0 * 0.85)
                    .offset(y: -(size / 2 - size * 0.09))
                    .rotationEffect(.degrees(Double(i) / 8.0 * 360))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                angle = 360
            }
        }
    }
}

// 메모 카드
struct MemoCardView: View {
    let title: String
    let preview: String
    var meta: String? = nil
    var classifying: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.appHeadline).foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
            Text(preview).font(.appSubhead).foregroundStyle(AppColor.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            if classifying {
                HStack(spacing: 6) {
                    DotSpinner(size: 16)
                    Text("분류 중…").font(.appCaption).foregroundStyle(AppColor.textTertiary)
                }
            } else if let meta {
                Text(meta).font(.appCaption).foregroundStyle(AppColor.textSecondary)
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(AppColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    }
}

// Primary 버튼
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.appHeadline)
                .foregroundStyle(AppColor.onAccent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
