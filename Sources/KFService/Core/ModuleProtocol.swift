import Foundation

/// Protocol for self-registering modules. Conformers provide a `register()`
/// method that the container calls during the boot phase.
///
/// ```
/// public struct KFKVModule: KFModule {
///     public init() {}
///     public func register() {
///         ServiceFactory.register(KVStore.self) { KFKVDefault(engine: .default()!) }
///     }
/// }
///
/// ServiceFactory.register(module: KFKVModule())
/// ```
public protocol KFModule {
    /// Startup priority. Lower values initialize first. Default 100.
    var priority: Int { get }

    /// Register services with ServiceFactory.
    func register()

    /// Called during `shutdown()` in reverse priority order.
    /// Use to flush, close files, or release external resources.
    func unregister()
}

public extension KFModule {
    var priority: Int { 100 }
    func unregister() {}
}

public extension ServiceFactory {

    /// Register a module — calls its `register()` method and retains the module
    /// instance for lifecycle callbacks (shutdown, system events).
    static func register(module: any KFModule) {
        module.register()
        store(module: module)
    }
}

// MARK: - New ModuleProtocol

/// 新模块协议（v3 DAG 模式）。
public protocol ModuleProtocol: AnyObject {
    static var dependencies: [ModuleID] { get }
    func performInit() async
}

public extension ModuleProtocol {
    static var dependencies: [ModuleID] { [] }
    func performInit() async {}
}

// MARK: - Backward compatibility

// KFModule preserved for existing module implementations (KFKVModule, KFLogModule, etc.)
// New code should adopt ModuleProtocol + @Module macro.
