// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// A group of startup tasks exported by a package.
///
/// Each package that needs initialization during app startup exports a
/// `StartupModule` with its tasks and their dependencies. The host calls
/// `Engine.run(modules:)` to auto-discover and execute them in DAG order.
///
/// ```
/// // In package (kflog):
/// public struct KFLogStartupModule: StartupModule {
///     private let config: KFLogConfig
///     public var tasks: [any StartupTask] { [KFLogStartupTask(config: config)] }
///     public init(config: KFLogConfig) { self.config = config }
/// }
///
/// // In host:
/// Engine.run(modules: [
///     KFKVStartupModule(config: kvConfig),
///     KFLogStartupModule(config: logConfig),
/// ])
/// ```
public protocol StartupModule {
    var tasks: [any StartupTask] { get }
}

/// Wraps arbitrary tasks into a module — useful for host-specific or test tasks.
public struct AdHocStartupModule: StartupModule {
    public let tasks: [any StartupTask]
    public init(_ tasks: [any StartupTask]) { self.tasks = tasks }
    public init(_ task: any StartupTask) { self.tasks = [task] }
}
