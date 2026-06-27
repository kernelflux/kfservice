// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// Conform your service class to this protocol to receive system events
/// forwarded by KFServiceManager. All methods are optional — implement only
/// the ones your service needs.
///
/// KFServiceManager subscribes to system notifications and network state
/// changes during `start()` and dispatches them to all cached service
/// instances that conform to this protocol.
public protocol KFSystemEventObserver: AnyObject {
    // MARK: App lifecycle

    func onEnterBackground()
    func onEnterForeground()
    func onMemoryWarning()
    func onWillTerminate()

    // MARK: Network

    /// Called when connectivity returns (cellular or Wi-Fi), after being unavailable.
    func onNetworkAvailable()
    /// Called when all connectivity is lost.
    func onNetworkUnavailable()
    /// Called when the active interface changes (e.g. Wi-Fi → cellular, cellular → Wi-Fi).
    func onNetworkInterfaceChanged(_ interface: KFNetworkInterface)
}

public extension KFSystemEventObserver {
    func onEnterBackground() {}
    func onEnterForeground() {}
    func onMemoryWarning() {}
    func onWillTerminate() {}

    func onNetworkAvailable() {}
    func onNetworkUnavailable() {}
    func onNetworkInterfaceChanged(_ interface: KFNetworkInterface) {}
}

/// Network interface type — Foundation-level enum so services don't need to import Network.
public enum KFNetworkInterface: Sendable {
    case wifi
    case cellular
    case wired
    case loopback
    case other
}
