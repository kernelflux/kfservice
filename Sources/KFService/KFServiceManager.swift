// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import Network

/// Lightweight service manager — protocol-based dependency injection without third-party frameworks.
///
/// ```
/// // Registration (app launch)
/// KFServiceManager.register(KFLogger.self) { KFLogDefault() }
/// KFServiceManager.register(KVStore.self)  { KFKVDefault() }
///
/// // Resolution (business code)
/// let logger = KFServiceManager.resolve(KFLogger.self)
/// logger.info("done")
///
/// // Runtime override (testing / A/B / disaster recovery)
/// KFServiceManager.register(KFLogger.self) { KFConsoleLogger() }
///
/// // Eager initialization — forces instantiation now rather than on first resolve
/// KFServiceManager.warmup(KVStore.self)
/// KFServiceManager.preload(KVStore.self, KFLogger.self)
/// ```
public final class KFServiceManager {
    private static var factories: [Key: () -> Any] = [:]
    private static var instances: [Key: Any] = [:]
    private static var modules: [(module: any KFModule, priority: Int)] = []
    private static var eventObserverTokens: [NSObjectProtocol] = []
    private static let lock = NSLock()
    private static var isObservingSystemEvents = false

    // MARK: - EventBus state

    private static var eventHandlers: [ObjectIdentifier: [(id: UUID, handler: (Any) -> Void)]] = [:]
    private static let eventLock = NSLock()

    // MARK: - Network state

    private static var pathMonitor: AnyObject?
    private static var lastNetworkInterface: KFNetworkInterface = .other
    private static var lastNetworkAvailable: Bool = true

    private struct Key: Hashable {
        let label: String
        init<T>(_ type: T.Type) {
            self.label = String(reflecting: type)
        }
        init(label: String) {
            self.label = label
        }
    }

    // MARK: - Module storage (internal)

    static func store(module: any KFModule) {
        lock.lock()
        defer { lock.unlock() }
        modules.append((module, module.priority))
        modules.sort { $0.priority < $1.priority }
    }

    // MARK: - Register

    /// Register a factory for a service protocol.
    /// Replaces any existing registration and clears the cached instance.
    public static func register<T>(_ type: T.Type = T.self, factory: @escaping () -> T) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(type)
        factories[key] = factory
        instances.removeValue(forKey: key)
    }

    // MARK: - Resolve

    /// Resolve a service instance. Caches the result after first creation.
    /// Calls `fatalError` if no registration exists — register before resolve.
    public static func resolve<T>(_ type: T.Type = T.self) -> T {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(type)
        if let cached = instances[key], let instance = cached as? T {
            return instance
        }
        guard let factory = factories[key] else {
            fatalError("KFServiceManager: no registration for '\(key.label)'. Call register(_:factory:) first.")
        }
        let instance = factory() as! T
        instances[key] = instance as Any
        return instance
    }

    /// Resolve — returns nil when no registration exists (no fatalError).
    /// Use this for optional services (e.g. analytics may or may not be wired).
    public static func resolveOptional<T>(_ type: T.Type = T.self) -> T? {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(type)
        if let cached = instances[key], let instance = cached as? T {
            return instance
        }
        guard let factory = factories[key] else { return nil }
        let instance = factory() as! T
        instances[key] = instance as Any
        return instance
    }

    /// Resolve — returns `defaultValue` if no registration exists (no fatalError).
    public static func resolve<T>(_ type: T.Type = T.self, default defaultValue: @autoclosure () -> T) -> T {
        resolveOptional(type) ?? defaultValue()
    }

    // MARK: - Orchestration

    /// Eagerly resolve and cache a service. Use for infrastructure that must
    /// initialize early (Crash, Log, KV). Fatal error if not registered.
    @discardableResult
    public static func warmup<T>(_ type: T.Type = T.self) -> T {
        resolve(type)
    }

    /// Batch warmup in call order. No topological sorting — caller controls
    /// the sequence by listing dependencies first.
    public static func preload(_ types: Any.Type...) {
        for type in types {
            let label = String(reflecting: type)
            lock.lock()
            let key = Key(label: label)
            guard let factory = factories[key] else {
                lock.unlock()
                continue
            }
            if instances[key] == nil {
                let instance = factory()
                instances[key] = instance as Any
            }
            lock.unlock()
        }
    }

    /// Initialize all registered services eagerly. Call after all modules are registered.
    /// Subscribes to system events and starts network path monitoring.
    ///
    /// ```
    /// KFServiceManager.register(module: KFKVModule(...))
    /// KFServiceManager.register(module: KFLogModule(...))
    /// KFServiceManager.start()
    /// ```
    public static func start() {
        lock.lock()
        let keys = Array(factories.keys)
        lock.unlock()
        for key in keys {
            lock.lock()
            if instances[key] == nil, let factory = factories[key] {
                let instance = factory()
                instances[key] = instance as Any
            }
            lock.unlock()
        }
        subscribeSystemEvents()
        if #available(iOS 12.0, macOS 10.14, *) { startNetworkMonitor() }
    }

    /// Shut down all modules in reverse priority order, clear cached instances,
    /// unsubscribe system events, stop network monitoring, and clean up event
    /// bus subscriptions. Factories are preserved — `start()` can be called
    /// again to re-initialize.
    public static func shutdown() {
        unsubscribeSystemEvents()
        if #available(iOS 12.0, macOS 10.14, *) { stopNetworkMonitor() }

        lock.lock()
        let reversed = modules.sorted { $0.priority > $1.priority }
        lock.unlock()

        for pair in reversed {
            pair.module.unregister()
        }

        lock.lock()
        instances.removeAll()
        modules.removeAll()
        lock.unlock()

        // EventBus: clear all subscriptions on full shutdown
        eventLock.lock()
        eventHandlers.removeAll()
        eventLock.unlock()
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
        lock.lock()
        let snapshot = instances.values.map { $0 as Any }
        lock.unlock()
        for instance in snapshot {
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

    // MARK: - EventBus

    /// Subscribe to events of a specific type. Returns a token — **retain it**
    /// to keep the subscription alive. When the token is deallocated, the
    /// handler is automatically removed.
    ///
    /// ```
    /// private var tokens: [KFEventToken] = []
    ///
    /// tokens.append(KFServiceManager.on(UserLoggedOut.self) { event in
    ///     // handle logout — called on the emitting thread
    /// })
    /// ```
    public static func on<T>(_ type: T.Type, _ handler: @escaping (T) -> Void) -> KFEventToken {
        let id = UUID()
        let key = ObjectIdentifier(T.self)
        let wrapped: (Any) -> Void = { value in
            if let event = value as? T { handler(event) }
        }

        eventLock.lock()
        eventHandlers[key, default: []].append((id, wrapped))
        eventLock.unlock()

        return KFEventToken { [id] in
            eventLock.lock()
            defer { eventLock.unlock() }
            eventHandlers[key]?.removeAll { $0.id == id }
            if eventHandlers[key]?.isEmpty == true {
                eventHandlers.removeValue(forKey: key)
            }
        }
    }

    /// Emit an event to all current subscribers of its type.
    /// Handlers are called on the emitting thread.
    ///
    /// ```
    /// KFServiceManager.emit(UserLoggedOut(timestamp: Date()))
    /// ```
    public static func emit<T>(_ event: T) {
        let key = ObjectIdentifier(T.self)
        eventLock.lock()
        let snapshot = eventHandlers[key] ?? []
        eventLock.unlock()
        for entry in snapshot {
            entry.handler(event)
        }
    }

    // MARK: - Introspection

    /// All registered service type names.
    public static var registeredServices: [String] {
        lock.lock()
        defer { lock.unlock() }
        return factories.keys.map(\.label).sorted()
    }

    /// Check whether a service type has been registered.
    public static func isRegistered<T>(_ type: T.Type) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return factories[Key(type)] != nil
    }

    // MARK: - Reset

    /// Clear the cached instance for a service. Next resolve will create a new one.
    public static func reset<T>(_ type: T.Type) {
        lock.lock()
        defer { lock.unlock() }
        instances.removeValue(forKey: Key(type))
    }

    /// Clear all registrations and cached instances.
    public static func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        factories.removeAll()
        instances.removeAll()
    }
}
