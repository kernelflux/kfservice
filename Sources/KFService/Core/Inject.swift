// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// Property wrapper that resolves a service from the shared container.
///
/// Missing registrations trigger a `fatalError` — they are programmer errors.
/// The wrapper delegates to the container for scope-based caching.
///
/// ```
/// @Inject(KVStore.self) private var store: any KVStore
/// @Inject(KVStore.self, name: "cache") private var cache: any KVStore
/// @Inject private var logger: any KFLogger
/// ```
@propertyWrapper
public struct Inject<T> {
    private let container: ServiceContainer
    private let type: T.Type
    private let name: String?

    public init(_ type: T.Type = T.self, name: String? = nil, container: ServiceContainer = .shared) {
        self.type = type
        self.name = name
        self.container = container
    }

    public var wrappedValue: T {
        guard let value = try? container.resolve(type, name: name) else {
            let label = name.map { "\(String(reflecting: T.self)) (name: \"\($0)\")" }
                ?? String(reflecting: T.self)
            fatalError(
                "Inject<\(label)>: service not registered in container."
            )
        }
        return value
    }
}
