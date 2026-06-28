import Foundation

/// A unit of startup work that the Engine schedules in dependency order.
///
/// Each task declares what it depends on and supplies a `run()` method that
/// resolves services from `ServiceContainer` and initializes them with host-provided config.
///
/// ```
/// final class CrashStartupTask: BaseStartupTask {
///     override var identifier: String { "com.kernelflux.crash" }
///     override var dependencies: [String] { ["com.kernelflux.log"] }
///     private let config: KFCrashConfig
///
///     init(config: KFCrashConfig) { self.config = config }
///
///     override func run() async throws {
///         let crash = try ServiceContainer.shared.resolve((any KFCrashService).self)
///         try crash.initialize(config: config)
///     }
/// }
/// ```
///
/// Inherit from `BaseStartupTask` for sensible defaults — `identifier` defaults to the type name,
/// `dependencies` to empty, `actorRequirement` to `.automatic`.
public protocol StartupTask: AnyObject {
    /// Unique identifier for this task. Other tasks declare dependencies on this string.
    var identifier: String { get }

    /// Identifiers of tasks that must complete before this task runs.
    var dependencies: [String] { get }

    /// Thread isolation requirement. Default `.automatic`.
    var actorRequirement: ActorRequirement { get }

    /// Execution priority within a layer. Lower values run first. Default 100.
    var priority: Int { get }

    /// Core work: resolve services from ServiceContainer and initialize with config.
    /// The Engine calls this in topological-dependency order.
    func run() async throws
}

public extension StartupTask {
    var priority: Int { 100 }
}

// MARK: - BaseStartupTask

/// Base class with sensible defaults. Override `identifier` and `run()` at minimum.
open class BaseStartupTask: StartupTask {
    /// Defaults to the type name (e.g. `"KFCrashStartupTask"`). Override for a stable identifier.
    open var identifier: String {
        String(describing: type(of: self))
    }

    open var dependencies: [String] { [] }
    open var actorRequirement: ActorRequirement { .automatic }
    open var priority: Int { 100 }

    /// Subclass must override.
    open func run() async throws {
        fatalError("Subclass must override run()")
    }

    public init() {}
}
