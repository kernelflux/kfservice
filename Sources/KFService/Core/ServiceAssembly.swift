// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// Groups related service registrations into a single installable unit.
///
/// Use assemblies to keep registrations organized by feature or layer.
/// Swap implementations for testing by providing a different assembly.
///
/// ```
/// struct LogAssembly: ServiceAssembly {
///     func assemble(container: ServiceContainer) {
///         container.register(KFLogger.self) { KFLogDefault() }
///         container.register(KFLogger.self, name: "console") { KFConsoleLogger() }
///     }
/// }
///
/// // Install all assemblies at once:
/// let assemblies: [ServiceAssembly] = [LogAssembly(), KVAssembly(), CrashAssembly()]
/// ServiceContainer.shared.install(assemblies)
/// ```
public protocol ServiceAssembly {
    /// Register all services this assembly provides into the given container.
    func assemble(container: ServiceContainer)
}

// MARK: - Container convenience

extension ServiceContainer {
    /// Install multiple assemblies into this container.
    /// Each assembly's `assemble(container:)` is called in order.
    public func install(_ assemblies: [ServiceAssembly]) {
        for assembly in assemblies {
            assembly.assemble(container: self)
        }
    }

    /// Install a single assembly.
    public func install(_ assembly: ServiceAssembly) {
        assembly.assemble(container: self)
    }
}
