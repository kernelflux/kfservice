// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import os

/// DI scope — controls instance lifetime.
public enum ServiceScope: Sendable {
    /// One instance, cached forever (default).
    case singleton
    /// New instance on every resolve. Not cached.
    case transient
    /// Weak reference; recreated if deallocated.
    /// Only valid for reference types (classes).
    case weak
}

/// Pure DI container — register, resolve, scope management.
///
/// Supports named registrations for distinguishing multiple instances
/// of the same protocol (e.g. two `KVStore` backends).
///
/// ```
/// let container = ServiceContainer()
/// container.register(KVStore.self) { KFKVDefault() }
/// container.register(KVStore.self, name: "cache") { CacheKVStore() }
/// let store = try container.resolve(KVStore.self)
/// let cache = try container.resolve(KVStore.self, name: "cache")
/// ```
public final class ServiceContainer {
    /// Global shared container.
    public static let shared = ServiceContainer()

    // MARK: - Internal types

    private final class WeakBox {
        private(set) weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    /// Composite key: type + optional qualifier name.
    fileprivate struct Key: Hashable, Sendable {
        let typeID: ObjectIdentifier
        let typeName: String
        let name: String?

        init(_ type: Any.Type, name: String? = nil) {
            self.typeID = ObjectIdentifier(type)
            self.typeName = String(reflecting: type)
            self.name = name
        }
    }

    private struct State {
        var registrations: [Key: (scope: ServiceScope, factory: () -> Any)] = [:]
        var singletonInstances: [Key: Any] = [:]
        var weakInstances: [Key: WeakBox] = [:]
        var parameterizedFactories: [Key: ([Any]) -> Any] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Weak reference to parent container for chain-lookup fallback.
    private weak var parent: ServiceContainer?

    public init(parent: ServiceContainer? = nil) {
        self.parent = parent
    }

    /// Create a child container that falls back to this container for unresolved services.
    public func newChild() -> ServiceContainer {
        ServiceContainer(parent: self)
    }

    // MARK: - Register

    /// Register a factory for a service protocol.
    /// Replaces any existing registration for the same type+name and clears the cached instance.
    public func register<T>(
        _ type: T.Type = T.self,
        name: String? = nil,
        scope: ServiceScope = .singleton,
        factory: @escaping () -> T
    ) {
        state.withLock { s in
            let key = Key(type, name: name)
            s.registrations[key] = (scope, factory)
            s.singletonInstances.removeValue(forKey: key)
            s.weakInstances.removeValue(forKey: key)
        }
    }

    /// Type-erased registration. Prefer `register(_:name:scope:factory:)` when the concrete type is known.
    public func register(_ type: Any.Type, name: String? = nil, scope: ServiceScope = .singleton, factory: @escaping () -> Any) {
        state.withLock { s in
            let key = Key(type, name: name)
            s.registrations[key] = (scope, factory)
            s.singletonInstances.removeValue(forKey: key)
            s.weakInstances.removeValue(forKey: key)
        }
    }

    // MARK: Parameterized register

    /// Register a factory that receives runtime arguments at resolve time.
    /// Parameterized factories always create a new instance (equivalent to `.transient`).
    public func register<T, A>(
        _ type: T.Type = T.self, name: String? = nil,
        factory: @escaping (ServiceContainer, A) -> T
    ) {
        let key = Key(type, name: name)
        state.withLock { s in
            s.parameterizedFactories[key] = { args in factory(self, args[0] as! A) }
        }
    }

    /// Register a factory that receives 2 runtime arguments.
    public func register<T, A, B>(
        _ type: T.Type = T.self, name: String? = nil,
        factory: @escaping (ServiceContainer, A, B) -> T
    ) {
        let key = Key(type, name: name)
        state.withLock { s in
            s.parameterizedFactories[key] = { args in factory(self, args[0] as! A, args[1] as! B) }
        }
    }

    /// Register a factory that receives 3 runtime arguments.
    public func register<T, A, B, C>(
        _ type: T.Type = T.self, name: String? = nil,
        factory: @escaping (ServiceContainer, A, B, C) -> T
    ) {
        let key = Key(type, name: name)
        state.withLock { s in
            s.parameterizedFactories[key] = { args in factory(self, args[0] as! A, args[1] as! B, args[2] as! C) }
        }
    }

    /// Register a factory that receives 4 runtime arguments.
    public func register<T, A, B, C, D>(
        _ type: T.Type = T.self, name: String? = nil,
        factory: @escaping (ServiceContainer, A, B, C, D) -> T
    ) {
        let key = Key(type, name: name)
        state.withLock { s in
            s.parameterizedFactories[key] = { args in factory(self, args[0] as! A, args[1] as! B, args[2] as! C, args[3] as! D) }
        }
    }

    /// Register a factory that receives 5 runtime arguments.
    public func register<T, A, B, C, D, E>(
        _ type: T.Type = T.self, name: String? = nil,
        factory: @escaping (ServiceContainer, A, B, C, D, E) -> T
    ) {
        let key = Key(type, name: name)
        state.withLock { s in
            s.parameterizedFactories[key] = { args in factory(self, args[0] as! A, args[1] as! B, args[2] as! C, args[3] as! D, args[4] as! E) }
        }
    }

    // MARK: - Resolve

    /// Resolve a service instance. Caching behavior depends on the registered scope.
    /// Falls back to parent container when not locally registered.
    /// Throws `ServiceError.notRegistered` if no registration exists for the type+name.
    public func resolve<T>(_ type: T.Type = T.self, name: String? = nil) throws -> T {
        let key = Key(type, name: name)
        let localResult: T? = state.withLock { s -> T? in
            guard let registration = s.registrations[key] else {
                return nil
            }
            switch registration.scope {
            case .singleton:
                if let cached = s.singletonInstances[key], let instance = cached as? T {
                    return instance
                }
                guard let instance = registration.factory() as? T else {
                    return nil
                }
                s.singletonInstances[key] = instance as Any
                return instance

            case .transient:
                return registration.factory() as? T

            case .weak:
                if let box = s.weakInstances[key], let cached = box.value as? T {
                    return cached
                }
                guard let instance = registration.factory() as? T else {
                    return nil
                }
                guard instance is AnyObject else {
                    return nil
                }
                s.weakInstances[key] = WeakBox(instance as AnyObject)
                return instance
            }
        }

        if let instance = localResult { return instance }
        if let parent { return try parent.resolve(type, name: name) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Resolve without throwing — returns nil when not registered.
    public func resolveOptional<T>(_ type: T.Type = T.self, name: String? = nil) -> T? {
        try? resolve(type, name: name)
    }

    /// Resolve with a default fallback.
    public func resolve<T>(_ type: T.Type = T.self, name: String? = nil, default defaultValue: @autoclosure () -> T) -> T {
        resolveOptional(type, name: name) ?? defaultValue()
    }

    // MARK: Parameterized resolve

    /// Resolve a service passing 1 runtime argument. Falls back to parent container.
    public func resolve<T, A>(_ type: T.Type = T.self, name: String? = nil, argument: A) throws -> T {
        let key = Key(type, name: name)
        if let factory = state.withLock({ $0.parameterizedFactories[key] }),
           let instance = factory([argument as Any]) as? T {
            return instance
        }
        if let parent { return try parent.resolve(type, name: name, argument: argument) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Resolve passing 2 runtime arguments.
    public func resolve<T, A, B>(_ type: T.Type = T.self, name: String? = nil, arg1: A, arg2: B) throws -> T {
        let key = Key(type, name: name)
        if let factory = state.withLock({ $0.parameterizedFactories[key] }),
           let instance = factory([arg1 as Any, arg2 as Any]) as? T {
            return instance
        }
        if let parent { return try parent.resolve(type, name: name, arg1: arg1, arg2: arg2) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Resolve passing 3 runtime arguments.
    public func resolve<T, A, B, C>(_ type: T.Type = T.self, name: String? = nil, arg1: A, arg2: B, arg3: C) throws -> T {
        let key = Key(type, name: name)
        if let factory = state.withLock({ $0.parameterizedFactories[key] }),
           let instance = factory([arg1 as Any, arg2 as Any, arg3 as Any]) as? T {
            return instance
        }
        if let parent { return try parent.resolve(type, name: name, arg1: arg1, arg2: arg2, arg3: arg3) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Resolve passing 4 runtime arguments.
    public func resolve<T, A, B, C, D>(_ type: T.Type = T.self, name: String? = nil, arg1: A, arg2: B, arg3: C, arg4: D) throws -> T {
        let key = Key(type, name: name)
        if let factory = state.withLock({ $0.parameterizedFactories[key] }),
           let instance = factory([arg1 as Any, arg2 as Any, arg3 as Any, arg4 as Any]) as? T {
            return instance
        }
        if let parent { return try parent.resolve(type, name: name, arg1: arg1, arg2: arg2, arg3: arg3, arg4: arg4) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Resolve passing 5 runtime arguments.
    public func resolve<T, A, B, C, D, E>(_ type: T.Type = T.self, name: String? = nil, arg1: A, arg2: B, arg3: C, arg4: D, arg5: E) throws -> T {
        let key = Key(type, name: name)
        if let factory = state.withLock({ $0.parameterizedFactories[key] }),
           let instance = factory([arg1 as Any, arg2 as Any, arg3 as Any, arg4 as Any, arg5 as Any]) as? T {
            return instance
        }
        if let parent { return try parent.resolve(type, name: name, arg1: arg1, arg2: arg2, arg3: arg3, arg4: arg4, arg5: arg5) }
        throw ServiceError.notRegistered(labelFor(T.self, name: name))
    }

    /// Type-erased resolve — internal use only (preload, system event dispatch).
    func _resolve(_ type: Any.Type) throws -> Any {
        let key = Key(type)
        let localResult: Any? = state.withLock { s -> Any? in
            guard let registration = s.registrations[key] else { return nil }
            switch registration.scope {
            case .singleton:
                if let cached = s.singletonInstances[key] { return cached }
                let instance = registration.factory()
                s.singletonInstances[key] = instance
                return instance
            case .transient:
                return registration.factory()
            case .weak:
                if let box = s.weakInstances[key], let cached = box.value { return cached }
                let instance = registration.factory()
                guard let object = instance as? AnyObject else { return nil }
                s.weakInstances[key] = WeakBox(object)
                return instance
            }
        }
        if let instance = localResult { return instance }
        if let parent { return try parent._resolve(type) }
        throw ServiceError.notRegistered(keyLabel(key))
    }

    // MARK: - Eager init

    /// Eagerly resolve and cache a service.
    @discardableResult
    public func warmup<T>(_ type: T.Type = T.self, name: String? = nil) throws -> T {
        try resolve(type, name: name)
    }

    /// Batch warmup in call order. Skips unregistered types silently.
    public func preload(_ types: Any.Type...) {
        for type in types {
            _ = try? _resolve(type)
        }
    }

    /// Eagerly initialize all registered services.
    public func initializeAll() {
        let keys = state.withLock { Array($0.registrations.keys) }
        for key in keys {
            state.withLock { s in
                guard let registration = s.registrations[key] else { return }
                switch registration.scope {
                case .singleton:
                    if s.singletonInstances[key] == nil {
                        s.singletonInstances[key] = registration.factory() as Any
                    }
                case .transient:
                    break
                case .weak:
                    if s.weakInstances[key] == nil {
                        if let object = registration.factory() as? AnyObject {
                            s.weakInstances[key] = WeakBox(object)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cache management

    /// Clear the cached instance. Next resolve creates a new one.
    public func reset<T>(_ type: T.Type, name: String? = nil) {
        let key = Key(type, name: name)
        state.withLock { s in
            _ = s.singletonInstances.removeValue(forKey: key)
            _ = s.weakInstances.removeValue(forKey: key)
            _ = s.parameterizedFactories.removeValue(forKey: key)
        }
    }

    /// Clear all registrations, cached instances, and parameterized factories.
    public func resetAll() {
        state.withLock { s in
            s.registrations.removeAll()
            s.singletonInstances.removeAll()
            s.weakInstances.removeAll()
            s.parameterizedFactories.removeAll()
        }
    }

    // MARK: - Introspection

    /// All registered service entries as human-readable strings (includes parent chain).
    public var registeredServices: [String] {
        var seen: Set<ServiceContainer.Key> = []
        var result: [String] = []
        var current: ServiceContainer? = self
        while let c = current {
            let localKeys = c.state.withLock { Array($0.registrations.keys) }
            for key in localKeys where seen.insert(key).inserted {
                result.append(keyLabel(key))
            }
            current = c.parent
        }
        return result.sorted()
    }

    /// Check whether a service type has been registered (any name). Checks parent chain.
    public func isRegistered<T>(_ type: T.Type, name: String? = nil) -> Bool {
        let key = Key(type, name: name)
        let localMatch = state.withLock { $0.registrations[key] != nil || $0.parameterizedFactories[key] != nil }
        if localMatch { return true }
        return parent?.isRegistered(type, name: name) ?? false
    }

    /// All cached instances (for system event dispatch).
    var cachedInstances: [Any] {
        state.withLock { s in
            let singletons = Array(s.singletonInstances.values)
            let weaks = s.weakInstances.values.compactMap(\.value)
            return singletons + weaks
        }
    }
}

// MARK: - Helpers

private func labelFor(_ type: Any.Type, name: String?) -> String {
    if let name { return "\(String(reflecting: type)) (name: \"\(name)\")" }
    return String(reflecting: type)
}

private func keyLabel(_ key: ServiceContainer.Key) -> String {
    if let name = key.name { return "\(key.typeName)::\(name)" }
    return key.typeName
}

// MARK: - ServiceError

public enum ServiceError: Error, Sendable {
    case notRegistered(String)
    case typeMismatch(String)
    case weakScopeRequiresReferenceType(String)
}
