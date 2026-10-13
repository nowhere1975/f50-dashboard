import Foundation
import SystemConfiguration

final class NetworkObserver {
    private var store: SCDynamicStore?
    var onChange: (() -> Void)?

    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "F50DashboardObserver" as CFString, { _, _, info in
            guard let info = info else { return }
            Unmanaged<NetworkObserver>.fromOpaque(info).takeUnretainedValue().onChange?()
        }, &context)
        guard let store = store else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/DNS"] as CFArray
        let patterns = ["State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/DNS",
                        "State:/Network/Interface/.*/Link"] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
    }

    deinit { if let store = store { SCDynamicStoreSetDispatchQueue(store, nil) } }
}
