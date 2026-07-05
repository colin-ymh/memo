import SwiftUI

// 타이포 스케일 — iOS 실제 앱은 시스템 폰트(SF Pro / Apple SD Gothic Neo)로 한글·라틴 처리.
// (Penpot 목업은 Noto Sans KR로 렌더했음)
extension Font {
    static let appLargeTitle = Font.system(size: 34, weight: .bold)
    static let appTitle      = Font.system(size: 22, weight: .bold)
    static let appHeadline   = Font.system(size: 17, weight: .semibold)
    static let appBody       = Font.system(size: 17, weight: .regular)
    static let appSubhead    = Font.system(size: 15, weight: .regular)
    static let appCaption    = Font.system(size: 13, weight: .regular)
    static let appFootnote   = Font.system(size: 12, weight: .regular)
}
