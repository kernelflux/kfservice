# KFService

A lightweight, protocol-based service manager for iOS — dependency injection, module lifecycle, system event distribution, network path monitoring, and a type-safe EventBus.

Built on two principles: **zero third-party dependencies**, and **explicit over magic** — no code generation, no runtime scanning, no annotation processing.

[中文文档](README_CN.md)

## Table of Contents

- [Installation](#installation)
- [Design Rationale](#design-rationale)
- [Core Concepts](#core-concepts)
  - [Service Locator vs DI Container](#service-locator-vs-di-container)
  - [Architecture Overview](#architecture-overview)
- [Service Registration & Resolution](#service-registration--resolution)
- [Module System & Lifecycle](#module-system--lifecycle)
- [System Event Observation](#system-event-observation)
- [Network Path Monitoring](#network-path-monitoring)
- [EventBus](#eventbus)
- [Thread Safety](#thread-safety)
- [Full API Reference](#full-api-reference)
- [Integration Guide](#integration-guide)
- [License](#license)

## Installation

**Swift Package Manager**

```
https://github.com/kernelflux/kfservice.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/kernelflux/kfservice.git", from: "1.0.0")
```

Then add `KFService` to your target's dependencies. Minimum deployment target: iOS 12.0.

> `Network.framework` is auto-linked by the package manifest.

---

## Design Rationale

### Service Locator vs DI Container

Most iOS DI frameworks (Swinject, Typhoon, DIP) are **containers** — you register types and the framework constructs object graphs, injecting dependencies through initializers or properties. This requires either:

- **Code generation** (Swinject + SwinjectAutoregistration, Hilt/Koin for Android)
- **Reflection** (DIP, old Typhoon)
- **Complex resolver chains** to satisfy constructor arguments

KFService takes the **service locator** path instead. Reasons:

1. **SDK-grade simplicity** — our target is infrastructure components (logging, KV store, crash reporting), not application-layer DI. These components rarely have deep dependency trees; they need *discovery*, not *construction*.

2. **Explicit control** — the factory closure is hand-written, so initialization order and configuration are visible at the call site. No "magic" resolution of nested dependencies.

3. **Runtime adaptability** — registering a new factory for the same protocol immediately replaces the cached instance. This enables A/B testing, feature flags, and runtime overrides without container rebuilds.

4. **No build phase overhead** — zero code generation keeps build times predictable.

### Architecture Overview

```
┌─────────────────────────────────────────────────┐
│                   KFServiceManager               │
│                                                  │
│  ┌──────────────┐  ┌──────────────┐              │
│  │  factories    │  │  instances   │              │
│  │  [Key: ()->T] │  │  [Key: Any]  │              │
│  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                      │
│         └────────┬────────┘                      │
│                  │ lock (NSLock)                  │
│                  ▼                               │
│  ┌──────────────────────────────┐               │
│  │  register / resolve / reset  │               │
│  └──────────────────────────────┘               │
│                                                  │
│  ┌──────────────────────┐                       │
│  │  modules              │                       │
│  │  [(KFModule, priority)]│                      │
│  └──────────┬───────────┘                       │
│             │                                    │
│  ┌──────────▼───────────┐                       │
│  │  start() / shutdown() │                      │
│  └──────────────────────┘                       │
│                                                  │
│  ┌─────────────────────────────┐                │
│  │  eventHandlers               │                │
│  │  [ObjectIdentifier: [(UUID, │                │
│  │    (Any)->Void)]]            │                │
│  └──────────┬──────────────────┘                │
│             │ eventLock (NSLock)                 │
│  ┌──────────▼───────────┐                       │
│  │  on() / emit()        │                       │
│  └──────────────────────┘                       │
│                                                  │
│  ┌──────────────────────────────┐               │
│  │  System events                │               │
│  │  NotificationCenter → observe │               │
│  │  NWPathMonitor → network      │               │
│  └──────────┬───────────────────┘               │
│             │                                    │
│  ┌──────────▼───────────┐                       │
│  │  dispatchToObservers  │                       │
│  │  snapshot → iterate   │                       │
│  └──────────────────────┘                       │
└─────────────────────────────────────────────────┘
```

**5 source files, ~400 lines total.** Each subsystem is in a single, self-contained file.

---

## Core Concepts

### Registration Key

Service types are identified by `String(reflecting:)`, which produces the fully-qualified type name (module + type). This means `MyApp.KFLogger` and `MyFramework.KFLogger` are distinct keys — no accidental collisions across modules.

```swift
private struct Key: Hashable {
    let label: String
    init<T>(_ type: T.Type) { self.label = String(reflecting: type) }
}
```

### Factory Closure & Instance Caching

Each registration stores a `() -> T` factory, not an instance. On first `resolve()`, the factory is called, the result is cached in `instances`, and subsequent resolves return the cached value. This is **lazy by default** — services that are never resolved are never constructed.

`register()` with a new factory for an already-registered type clears the cached instance, so the next `resolve()` constructs a new one with the new factory. This is the mechanism for runtime overrides.

---

## Service Registration & Resolution

### Basic Registration

```swift
// Protocol
protocol KVStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

// Implementation
class KFKVDefault: KVStore { ... }

// Registration
KFServiceManager.register(KVStore.self) { KFKVDefault() }
```

The factory is `@escaping` — construction is deferred until first resolve.

### Resolution

```swift
// Fatal error if not registered
let store = KFServiceManager.resolve(KVStore.self)

// nil if not registered (for optional services like analytics)
let tracker = KFServiceManager.resolveOptional(Analytics.self)

// With default — no fatalError, clean for testing
let cache = KFServiceManager.resolve(CacheService.self, default: MemoryCache())
```

`resolve()` is intentionally strict (`fatalError` on missing registration) — infrastructure services should fail fast at launch, not silently degrade.

### Runtime Override

```swift
// Register initial implementation
KFServiceManager.register(KVStore.self) { KFKVDefault() }

// Later: override for testing / A/B test / incident mitigation
KFServiceManager.register(KVStore.self) { MockKVStore() }

// Next resolve returns MockKVStore
let store = KFServiceManager.resolve(KVStore.self)
```

### Eager Initialization

Some services must initialize early — crash reporter (to catch early crashes), logger (to capture boot logs), KV store (to read feature flags before UI).

```swift
// Single service
KFServiceManager.warmup(KVStore.self)   // returns the instance

// Batch — caller controls order by listing dependencies first
KFServiceManager.preload(KVStore.self, KFLogger.self, KFNetwork.self)
```

`warmup()` is just `resolve()` with `@discardableResult`. `preload()` skips unregistered types silently — safe to call for optional services.

---

## Module System & Lifecycle

### KFModule Protocol

A module is a grouping of related service registrations with lifecycle hooks:

```swift
public protocol KFModule {
    var priority: Int { get }       // default: 100 (lower = earlier start)
    func register()                 // called when module is registered
    func unregister()               // called during shutdown, reverse priority order
}
```

### Priority Semantics

Priority controls both **startup order** (ascending: 100 before 200) and **shutdown order** (descending: 200 before 100). This ensures that foundational services initialize first and tear down last.

| Priority range | Typical use |
|---------------|-------------|
| 0–99 | Platform-level: crash reporter, logging, KV store |
| 100 (default) | General infrastructure |
| 101–200 | Feature modules, analytics, networking |

```swift
struct KFCrashModule: KFModule {
    let priority = 10   // very early — must be first to catch crashes

    func register() {
        KFServiceManager.register(KFCrashProtocol.self) { KFCrashDefault.shared }
    }

    func unregister() {
        // flush pending crash reports
        KFServiceManager.resolve(KFCrashProtocol.self).sync()
    }
}

struct KFNetworkModule: KFModule {
    let priority = 300  // late — depends on KV (for base URL config)

    func register() {
        let baseURL = KFServiceManager.resolve(KVStore.self).string(forKey: "base_url")
        KFServiceManager.register(APIClient.self) { APIClientDefault(baseURL: baseURL!) }
    }
}
```

### Registration

```swift
// Module registers its services immediately, and is retained for lifecycle
KFServiceManager.register(module: KFCrashModule())
KFServiceManager.register(module: KFKVModule())
```

### Start & Shutdown

```swift
// Boot: eager-initialize ALL registered services, subscribe to system events,
// start network monitoring
KFServiceManager.start()

// Graceful shutdown: reverse-priority unregister → clear instances → clear
// modules → clear EventBus → stop network monitor → unsubscribe system events
KFServiceManager.shutdown()
```

`shutdown()` preserves factory registrations — `start()` can be called again to reinitialize everything.

---

## System Event Observation

`KFSystemEventObserver` is a protocol that services conform to for receiving app lifecycle and network events. All methods have default empty implementations — implement only what your service needs.

```swift
public protocol KFSystemEventObserver: AnyObject {
    func onEnterBackground()
    func onEnterForeground()
    func onMemoryWarning()
    func onWillTerminate()

    func onNetworkAvailable()
    func onNetworkUnavailable()
    func onNetworkInterfaceChanged(_ interface: KFNetworkInterface)
}
```

### How It Works

1. `start()` calls `subscribeSystemEvents()`, which adds block-based observers for 4 UIKit notifications via `NotificationCenter`.
2. When a notification fires, `dispatchToObservers` snapshots all cached instances under `lock`, then iterates the snapshot outside the lock, calling the callback on any instance that conforms to `KFSystemEventObserver`.
3. `shutdown()` calls `unsubscribeSystemEvents()`, removing each observer token individually.

Notification names are defined as raw string constants in `Notification.Name.KFSystem` to avoid importing UIKit in the SPM target.

### Usage

```swift
extension KFLogDefault: KFSystemEventObserver {
    func onEnterBackground() { flush() }
    func onMemoryWarning() { flush() }
}
```

The observer pattern means **services opt in** — KFServiceManager does not need to know about each service's lifecycle needs. It simply broadcasts events, and each service decides what to do.

---

## Network Path Monitoring

KFServiceManager monitors network connectivity using `NWPathMonitor` (iOS 12+) and dispatches changes to `KFSystemEventObserver` instances.

### Interface Types

```swift
public enum KFNetworkInterface: Sendable {
    case wifi
    case cellular
    case wired
    case loopback
    case other
}
```

### Deduplication Logic

The monitor tracks `lastNetworkAvailable` and `lastNetworkInterface`. On each path update:

| Condition | Event dispatched |
|-----------|-----------------|
| `!available → available` | `onNetworkAvailable()` |
| `available → !available` | `onNetworkUnavailable()` |
| Interface change while still available | `onNetworkInterfaceChanged(_:)` |
| No change | nothing dispatched |

This prevents repeated "available" callbacks that `NWPathMonitor` can produce on transient network changes.

### Threading

The monitor runs on `.global(qos: .default)`. State updates (`lastNetworkAvailable`, `lastNetworkInterface`) happen on the monitor's queue without locking — they are written before `dispatchToObservers` reads them, and the dispatch happens synchronously on the same queue.

---

## EventBus

A type-safe, in-process publish/subscribe mechanism for service-layer events. Designed for scenarios like: user logged out, auth token refreshed, entitlement changed, risk assessment triggered.

### Design goals

| Concern | Mechanism |
|---------|-----------|
| Memory safety | `KFEventToken` auto-unsubscribes on `deinit` — no forgotten handlers |
| Performance | Separate `eventLock` from the main service `lock`; handlers snapshotted under lock, invoked outside lock |
| Type safety | Events keyed by `ObjectIdentifier(T.self)` — no string-based event names |
| Threading | Handlers called on the **emitting thread** (no implicit queue hop) |

### Subscribe

```swift
// Define your event
struct UserLoggedOut {
    let timestamp: Date
}

// Subscribe — retain the token
private var tokens: [KFEventToken] = []

tokens.append(KFServiceManager.on(UserLoggedOut.self) { event in
    // Clear user-specific caches
    imageCache.removeAll()
    // Called on whatever thread emit() was called on
})
```

### Emit

```swift
KFServiceManager.emit(UserLoggedOut(timestamp: Date()))
```

### Unsubscribe

Two paths:

```swift
// 1. Automatic — when token is deallocated (owner deinits, or set to nil)
token = nil

// 2. Explicit — keep the property but cancel immediately
token.cancel()

// 3. Bulk — shutdown() clears all handlers
```

### KFEventToken Internals

The token stores a single closure `() -> Void` that captures only the handler ID, not the handler itself. On `deinit`, it acquires `eventLock`, removes the handler by ID from the `eventHandlers` dictionary, and cleans up empty entries. This incurs O(n) per-cancel where n is the handler count for that event type — acceptable since unsubscribe frequency is low relative to emit frequency. Emit is O(1) snapshot.

---

## Thread Safety

KFServiceManager uses two independent locks to minimize contention:

| Lock | Protects | Hot path |
|------|----------|----------|
| `lock` | `factories`, `instances`, `modules` | `resolve()` — called frequently |
| `eventLock` | `eventHandlers` | `emit()` — called on business events |

### Resolve hot path

```
resolve()
  lock.lock()
  if cached → return    ← hot path: O(1), lock held for nanoseconds
  lock.unlock()
  factory()             ← construction happens OUTSIDE the lock
  lock.lock()
  cache instance
  lock.unlock()
```

The common case (already cached) is a dictionary lookup under a lock — minimal contention.

### Dispatch pattern

Both system events and EventBus use **snapshot-then-dispatch**:

```
lock.lock()
snapshot = collection.copy()
lock.unlock()

for item in snapshot {
    callback(item)       // handler runs outside lock — cannot deadlock
}
```

This means callbacks that call back into KFServiceManager (e.g., resolving another service) are safe — they won't deadlock on re-entrant lock acquisition because `NSLock` is not recursive and the lock is not held during callback execution.

---

## Full API Reference

### Registration & Resolution

| Method | Description |
|--------|-------------|
| `register(_:factory:)` | Register a factory for a protocol. Replaces existing factory, clears cached instance |
| `resolve(_:)` | Get or create a cached instance. `fatalError` if not registered |
| `resolveOptional(_:)` | Get or create a cached instance. Returns `nil` if not registered |
| `resolve(_:default:)` | Resolve with `@autoclosure` fallback value |

### Module Lifecycle

| Method | Description |
|--------|-------------|
| `register(module:)` | Register a `KFModule` — calls `module.register()`, retains for lifecycle |
| `start()` | Eager-initialize all registrations; subscribe to system events; start network monitor |
| `shutdown()` | Reverse-priority teardown; clear instances, modules, and event handlers |

### Orchestration

| Method | Description |
|--------|-------------|
| `warmup(_:)` | Eagerly resolve & cache a single service. `@discardableResult` |
| `preload(_:)` | Batch warmup in caller-specified order. Silently skips unregistered types |
| `isRegistered(_:)` | Check whether a service type has been registered |
| `registeredServices` | Sorted array of registered type names (debug/introspection) |

### State Management

| Method | Description |
|--------|-------------|
| `reset(_:)` | Clear cached instance for one service. Next `resolve()` constructs a new one |
| `resetAll()` | Clear all registrations and cached instances |

### EventBus

| Method | Description |
|--------|-------------|
| `on(_:handler:) -> KFEventToken` | Subscribe to an event type. Retain the token to stay subscribed |
| `emit(_:)` | Send event to all subscribers of its type. Handlers called on current thread |

---

## Integration Guide

### Typical App Launch Sequence

```swift
// AppDelegate.application(_:didFinishLaunchingWithOptions:)

// Phase 1: Register modules in dependency order
KFServiceManager.register(module: KFCrashModule())     // priority 10
KFServiceManager.register(module: KFKVModule())         // priority 100
KFServiceManager.register(module: KFLogModule())        // priority 200
KFServiceManager.register(module: KFNetworkModule())    // priority 300

// Phase 2: Manual overrides or conditional registration
#if DEBUG
KFServiceManager.register(KVStore.self) { MockKVStore() }
#endif

// Phase 3: Start the service manager
KFServiceManager.start()
```

### Shutdown (optional)

```swift
// AppDelegate.applicationWillTerminate(_:)
KFServiceManager.shutdown()
```

### Using Services in Business Code

```swift
class UserProfileViewController: UIViewController {
    // Prefer resolve() for required services — fail fast
    private let logger = KFServiceManager.resolve(KFLogger.self)
    private let store  = KFServiceManager.resolve(KVStore.self)

    // Use resolveOptional for optional services
    private let analytics = KFServiceManager.resolveOptional(Analytics.self)

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("profile loaded")
        analytics?.track(.screenView("profile"))
    }
}
```

### Listening to Events

```swift
class CartManager {
    private var tokens: [KFEventToken] = []

    init() {
        tokens.append(KFServiceManager.on(UserLoggedOut.self) { [weak self] _ in
            self?.clearCart()
        })
        tokens.append(KFServiceManager.on(EntitlementChanged.self) { [weak self] event in
            self?.refreshPricing(for: event.tier)
        })
    }

    // tokens deinit → all handlers auto-removed
}
```

### Testing

```swift
final class MyServiceTests: XCTestCase {
    override func tearDown() {
        KFServiceManager.resetAll()
        super.tearDown()
    }

    func testWithMock() {
        KFServiceManager.register(KVStore.self) { MockKVStore() }
        let store = KFServiceManager.resolve(KVStore.self)
        // ...
    }
}
```

> Note: `resetAll()` clears registrations but does **not** unsubscribe system events or stop the network monitor. Use `shutdown()` for that.

---

## Source Layout

```
Sources/KFService/
├── KFServiceManager.swift           — Service locator, lifecycle, system events, network monitor, EventBus
├── KFModule.swift                   — KFModule protocol + register(module:) extension
├── KFSystemEventObserver.swift      — Observer protocol + KFNetworkInterface enum
├── KFSystemNotifications.swift      — UIKit notification name constants (no UIKit import)
└── KFEventToken.swift               — Auto-unsubscribing subscription token
```

## License

[MIT](LICENSE) — Copyright (c) 2026 KernelFlux
