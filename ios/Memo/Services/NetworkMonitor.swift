import Foundation
import Network

// 온라인 여부 감지. 오프라인 배너 + 재연결 시 동기화 트리거에 사용.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.monitor")
    var onReconnect: (() -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = online
                if online && wasOffline { self.onReconnect?() }
            }
        }
        monitor.start(queue: queue)
    }
}
