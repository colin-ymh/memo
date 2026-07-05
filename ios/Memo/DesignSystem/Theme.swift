import SwiftUI

// 디자인 시스템 색 — semantic 토큰(라이트/다크). 값은 Penpot 디자인시스템과 동일.
// OS 다크모드 전환 시 자동 반영(UIColor dynamic provider).
enum AppColor {
    static let bgCanvas     = dyn(0xFFFFFF, 0x000000)
    static let bgSurface    = dyn(0xF7F7F8, 0x121214)
    static let bgElevated   = dyn(0xFFFFFF, 0x1C1C1E)
    static let textPrimary  = dyn(0x1C1C1E, 0xF7F7F8)
    static let textSecondary = dyn(0x8A8A8F, 0xA8A8AE)
    static let textTertiary = dyn(0xA8A8AE, 0x636367)
    static let borderDefault = dyn(0xE1E1E4, 0x2C2C2E)
    static let borderStrong = dyn(0xC9C9CE, 0x48484A)
    static let accent       = dyn(0x000000, 0xFFFFFF)
    static let onAccent     = dyn(0xFFFFFF, 0x000000)
    static let fieldBg      = dyn(0xF7F7F8, 0x1C1C1E)
    static let danger       = dyn(0xE5484D, 0xD3383D)
    static let onDanger     = dyn(0xFFFFFF, 0xFFFFFF)
}

// spacing/radius 스케일(토큰과 동일)
enum Space {
    static let x1: CGFloat = 4, x2: CGFloat = 8, x3: CGFloat = 12, x4: CGFloat = 16
    static let x5: CGFloat = 20, x6: CGFloat = 24, x8: CGFloat = 32, x10: CGFloat = 40
}
enum Radius {
    static let sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, full: CGFloat = 999
}

private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
    })
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue:  CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
