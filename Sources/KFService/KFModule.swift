import Foundation

/// Protocol for self-registering modules. Conformers provide a `register()`
/// method that the container calls during the boot phase.
///
/// ```
/// public struct KFKVModule: KFModule {
///     public init() {}
///     public func register() {
///         KFServiceManager.register(KVStore.self) { KFKVDefault(engine: .default()!) }
///     }
/// }
///
/// KFServiceManager.register(module: KFKVModule())
/// ```
public protocol KFModule {
    /// Startup priority. Lower values initialize first. Default 100.
    var priority: Int { get }

    /// Register services with KFServiceManager.
    func register()

    /// Called during `shutdown()` in reverse priority order.
    /// Use to flush, close files, or release external resources.
    func unregister()
}

public extension KFModule {
    var priority: Int { 100 }
    func unregister() {}
}

public extension KFServiceManager {

    /// Register a module — calls its `register()` method and retains the module
    /// instance for lifecycle callbacks (shutdown, system events).
    static func register(module: any KFModule) {
        module.register()
        store(module: module)
    }
}
