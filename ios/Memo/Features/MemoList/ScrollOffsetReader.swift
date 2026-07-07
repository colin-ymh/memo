import SwiftUI
import UIKit

// List 하부 UIScrollView의 contentOffset.y를 직접 관찰.
// (SwiftUI PreferenceKey는 List 셀에서 부모로 전파가 안 돼 스크롤 감지에 못 씀.)
struct ScrollOffsetReader: UIViewRepresentable {
    let onChange: @Sendable (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let v = ProbeView()
        let cb = onChange
        v.onFoundScrollView = { sv in
            context.coordinator.attach(sv, onChange: cb)
        }
        return v
    }
    func updateUIView(_ uiView: ProbeView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var observation: NSKeyValueObservation?
        @MainActor func attach(_ scrollView: UIScrollView, onChange: @escaping @Sendable (CGFloat) -> Void) {
            guard observation == nil else { return }
            observation = scrollView.observe(\.contentOffset, options: [.new]) { _, change in
                if let y = change.newValue?.y { onChange(y) }  // CGPoint=Sendable, no MainActor 접근
            }
        }
    }

    // window에 붙는 시점에 상위 UIScrollView를 찾아 콜백(타이밍 안전).
    final class ProbeView: UIView {
        var onFoundScrollView: ((UIScrollView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var v: UIView? = superview
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            if let sv = v as? UIScrollView { onFoundScrollView?(sv) }
        }
    }
}
