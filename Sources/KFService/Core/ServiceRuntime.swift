// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import Network

/// Owns the app-level runtime environment: system event forwarding, network
/// monitoring, and start/shutdown lifecycle.
///
/// ```
/// // Bootstrap
/// ServiceRuntime.start()
///
/// // Shutdown
/// ServiceRuntime.shutdown()
/// ```
public final class ServiceRuntime {

    /// Global shared runtime.
    public static let shared = ServiceRuntime()

    // MARK: - System events (internal state)

    private static var eventObserverTokens: [NSObjectProtocol] = []
    private static var isObservingSystemEvents = false

    // MARK: - Network monitoring

    private static var pathMonitor: AnyObject?
    private static var lastNetworkInterface: KFNetworkInterface = .other
    private static var lastNetworkAvailable: Bool = true

    private init() {}

    // MARK: - Lifecycle

    /// Initialize all registered services, subscribe system events, start network monitor.
    public static func start() {
        ServiceContainer.shared.initializeAll()
        subscribeSystemEvents()
        if #available(iOS 12.0, macOS 10.14, *) { startNetworkMonitor() }
    }

    /// Shut down system events and network monitoring. Clear all cached instances.
    /// Factories are preserved — `start()` can be called again.
    public static func shutdown() {
        unsubscribeSystemEvents()
        if #available(iOS 12.0, macOS 10.14, *) { stopNetworkMonitor() }
        ServiceEventBus.shared.reset()
        ServiceContainer.shared.resetAll()
    }

    // MARK: - System events

    private static func subscribeSystemEvents() {
        guard !isObservingSystemEvents else { return }
        isObservingSystemEvents = true

        let center = NotificationCenter.default
        eventObserverTokens = [
            center.addObserver(forName: Notification.Name.KFSystem.didEnterBackground, object: nil, queue: nil) { _ in
                dispatchToObservers { $0.onEnterBackground() }
            },
            center.addObserver(forName: Notification.Name.KFSystem.willEnterForeground, object: nil, queue: nil) { _ in
                dispatchToObservers { $0.onEnterForeground() }
            },
            center.addObserver(forName: Notification.Name.KFSystem.didReceiveMemoryWarning, object: nil, queue: nil) { _ in
                dispatchToObservers { $0.onMemoryWarning() }
            },
            center.addObserver(forName: Notification.Name.KFSystem.willTerminate, object: nil, queue: nil) { _ in
                dispatchToObservers { $0.onWillTerminate() }
            },
        ]
    }

    private static func unsubscribeSystemEvents() {
        guard isObservingSystemEvents else { return }
        isObservingSystemEvents = false
        for token in eventObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        eventObserverTokens.removeAll()
    }

    private static func dispatchToObservers(_ callback: (KFSystemEventObserver) -> Void) {
        for instance in ServiceContainer.shared.cachedInstances {
            if let observer = instance as? KFSystemEventObserver {
                callback(observer)
            }
        }
    }

    // MARK: - Network monitoring

    @available(iOS 12.0, macOS 10.14, *)
    private static func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor

        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            let newInterface = mapNWInterface(path)

            let availabilityChanged = available != lastNetworkAvailable
            let interfaceChanged = !availabilityChanged && newInterface != lastNetworkInterface

            lastNetworkAvailable = available
            lastNetworkInterface = newInterface

            if availabilityChanged {
                if available {
                    dispatchToObservers { $0.onNetworkAvailable() }
                } else {
                    dispatchToObservers { $0.onNetworkUnavailable() }
                }
            } else if interfaceChanged {
                dispatchToObservers { $0.onNetworkInterfaceChanged(newInterface) }
            }
        }
        monitor.start(queue: .global(qos: .default))
    }

    @available(iOS 12.0, macOS 10.14, *)
    private static func stopNetworkMonitor() {
        (pathMonitor as? NWPathMonitor)?.cancel()
        pathMonitor = nil
    }

    @available(iOS 12.0, macOS 10.14, *)
    private static func mapNWInterface(_ path: NWPath) -> KFNetworkInterface {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.loopback) { return .loopback }
        return .other
    }
}
