# KFService

A lightweight service container + DAG-based startup scheduler. Zero external dependencies.

```
Engine (Facade)
├── ServiceFactory (Service Container)
└── StartupScheduler (Startup Scheduler)
    ├── DependencyGraph (DAG + Kahn's + Tarjan's)
    └── StartupTracer (Performance Tracing)
```

Inspired by Alibaba BeeHive (3-layer separation), ByteDance Douyin (DAG parallel scheduling), Meituan Kylin (T0 timing), and Tencent WeChat (timeout degradation).

[中文文档](README_CN.md)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Core Types](#core-types)
- [Module Definition](#module-definition)
- [Service Registration & Resolution](#service-registration--resolution)
- [DAG Scheduling](#dag-scheduling)
- [Threading Model](#threading-model)
- [Performance Tracing](#performance-tracing)
- [Migration Guide (v2 → v3)](#migration-guide)
- [Comparison with Industry](#comparison-with-industry)
- [Full API Reference](#full-api-reference)
- [Thread Safety](#thread-safety)
- [License](#license)

---

## Quick Start

### 1. Define modules with explicit dependencies

```swift
@Module(depends: [])                    // no dependencies
final class LogModule: ModuleProtocol {
    func performInit() async {
        ServiceFactory.register(KFLogger.self) { LogService() }
    }
}

@Module(depends: [LogModule.self])      // compile-time type safety
final class CrashModule: ModuleProtocol {
    func performInit() async {
        ServiceFactory.register(KFCrashService.self) { CrashService() }
    }
}

@Module(depends: [LogModule.self], on: .background(.utility))
final class AnalyticsModule: ModuleProtocol {
    func performInit() async {
        await preloadDatasets()  // background init, won't block main thread
    }
}

@Module(depends: [], lazy: true)        // lazy loading
final class SecurityModule: ModuleProtocol {
    func performInit() async { }
}
```

### 2. Start in one line

```swift
// App.swift
try await Engine.run()
```

Or with config and delegate:

```swift
Engine.delegate = self
try await Engine.run(config: StartupConfig(
    maxBackgroundConcurrency: 4,
    enableTracing: true
))
```

### 3. Use services anywhere

```swift
let log = ServiceFactory.resolve(KFLogger.self)
log.info("App started")
let crash = ServiceFactory.resolve((any KFCrashService).self)
```

**3 lines to define modules → 1 line to start → use anywhere.**

---

## Architecture

### 3-Layer Separation + Facade

```
┌──────────────────────────────────────────────────────────┐
│  Facade: Engine                                           │
│  Engine.run() → orchestrates ServiceFactory + StartupScheduler    │
└────────────────────────┬─────────────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         ▼                               ▼
┌────────────────────┐   ┌──────────────────────────────┐
│ ServiceFactory      │   │ StartupScheduler              │
│ register / resolve  │   │ DependencyGraph.sort/layers  │
│ warmup / preload    │   │ executeLayer → 分层并行       │
│ EventBus            │   │ StartupTracer                 │
└────────────────────┘   └──────────────────────────────┘
         │                          │
         └──────────┬───────────────┘
                    ▼
         ┌────────────────────┐
         │ ModuleProtocol     │
         │ @Module(depends:)  │
         │ (声明层，二者共享)    │
         └────────────────────┘
```

### File Structure

```
Sources/KFService/
├── Engine.swift                  Facade
├── Core/
│   ├── ServiceFactory.swift      (Container)
│   ├── ModuleProtocol.swift      (Protocol)
│   ├── KFEventToken.swift        事件订阅令牌
│   ├── KFSystemEventObserver.swift 系统事件
│   └── KFSystemNotifications.swift
└── Startup/
    ├── DependencyGraph.swift      (DAG + Kahn + Tarjan)
    ├── StartupScheduler.swift      (Scheduler)
    └── StartupTracer.swift        (Tracing)
```

---

## Core Types

### ModuleID

```swift
public struct ModuleID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String)
    public init(_ type: ModuleProtocol.Type)  // compile-time type-safe
}
```

### ActorRequirement — Tri-State Thread Declaration

```swift
public enum ActorRequirement: Sendable {
    case mainActor                          // must run on MainActor
    case background(DispatchQoS.QoSClass)   // must run in background
    case automatic                          // scheduler decides (default)
}
```

### ModuleNode — DAG Node

```swift
public struct ModuleNode: Sendable {
    public let id: ModuleID
    public let dependencies: [ModuleID]
    public let factory: @Sendable () async -> Void
    public let priority: Int
    public let actorRequirement: ActorRequirement
    public let maxExecTime: TimeInterval?
}
```

### DependencyGraph

```swift
public struct DependencyGraph: Sendable {
    /// DSL builder
    public init(@GraphBuilder _ build: () -> [ModuleNode])

    /// Tarjan's SCC cycle detection
    public func detectCycles() -> [[ModuleID]]

    /// Kahn's topological sort → layered parallel structure
    public func topologicalSort() throws -> [[ModuleNode]]

    /// Validate graph
    public func validate() throws
}
```

---

## Module Definition

### @Module macro (recommended)

```swift
@Module(depends: [LogModule.self], on: .mainActor, lazy: false)
final class CrashModule: ModuleProtocol {
    func performInit() async { ... }
}
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `depends` | `[ModuleProtocol.Type]` | `[]` | Compile-time type-safe dependencies |
| `on` | `ActorRequirement` | `.automatic` | Thread requirement |
| `lazy` | `Bool` | `false` | Lazy load on first use |
| `maxExecTime` | `TimeInterval?` | `nil` | Timeout degradation threshold |

### ModuleProtocol

```swift
public protocol ModuleProtocol: AnyObject {
    static var dependencies: [ModuleID] { get }
    func performInit() async
}
```

### KFModule (v2 compatibility)

The existing `KFModule` protocol is preserved for backward compatibility:

```swift
public protocol KFModule {
    var priority: Int { get }
    func register()
    func unregister()
}

ServiceFactory.register(module: myModule)
```

---

## Service Registration & Resolution

### Register a service

```swift
ServiceFactory.register(KFLogger.self) { LogService() }
```

### Resolve a service

```swift
let log = ServiceFactory.resolve(KFLogger.self)
// fatalError if unregistered

let kv = ServiceFactory.resolveOptional(KVStore.self)
// nil if unregistered
```

### Warmup / preload

```swift
ServiceFactory.warmup(KVStore.self)
ServiceFactory.preload(KVStore.self, KFLogger.self)
```

### EventBus

```swift
// Subscribe (keep token alive)
let token = ServiceFactory.on(UserLoggedOut.self) { event in
    // handle event
}

// Emit
ServiceFactory.emit(UserLoggedOut(timestamp: Date()))
```

### System Events

```swift
class MyService: KFSystemEventObserver {
    func onEnterBackground() { /* pause work */ }
    func onEnterForeground() { /* resume work */ }
    func onMemoryWarning()   { /* flush cache */ }
    func onWillTerminate()   { /* save state */ }

    func onNetworkAvailable()        { /* reconnect */ }
    func onNetworkUnavailable()      { /* go offline */ }
    func onNetworkInterfaceChanged(_ interface: KFNetworkInterface) { ... }
}
```

---

## DAG Scheduling

### Execution Flow

```
Phase 1: Validate
  Tarjan's SCC → detect strongly connected components
  If cycles found → report and abort

Phase 2: Sort
  Kahn's Algorithm → layered output [[Layer0], [Layer1], ...]
  Modules in same layer have no dependencies → can run in parallel

Phase 3: Execute
  for each layer:
    Step 1: MainActor modules serially (Meituan pattern)
    Step 2: Background modules in parallel (ByteDance pattern)
    Step 3: Timeout degradation (Tencent pattern)
```

### Lifecycle

```swift
public protocol StartupDelegate: AnyObject {
    func startupDidUpdatePhase(_ phase: StartupPhase)
    func startupDidComplete(with report: StartupReport)
    func startupDidFail(with error: Error)
}
```

### StartupScheduler

```swift
@MainActor
public final class StartupScheduler {
    public init(config: StartupConfig = .default)
    public func executeLayers(_ layers: [[ModuleNode]], stage: Stage) async throws
}
```

### StartupConfig

```swift
public struct StartupConfig: Sendable {
    public var maxBackgroundConcurrency: Int  // 默认 4
}
```

---

## Threading Model

### Per-Layer Execution

```
  ┌────────────────────────────────────────┐
  │ Step 1: MainActor serial execution          │  ← Meituan pattern
  │  Modules sorted by priority, executed one by one  │  Avoid main/bg contention
  ├────────────────────────────────────────┤
  │ Step 2: 后台模块并行执行                 │  ← 字节模式
  │  withThrowingTaskGroup parallel execution  │
  │  AsyncSemaphore(max: 4) as upper limit     │
  ├────────────────────────────────────────┤
  │ Step 3: Timeout degradation                │  ← Tencent pattern
  │  Module exceeds maxExecTime → throws timeout │
  └────────────────────────────────────────┘
```

### Visualization

```
Layer 0:
  Log_init(main) [30ms] ───────────────────────────

Layer 1 (main serial ‖ bg parallel):
  KV_init(bg)   [20ms] ────┐
  Crash_init(main) [50ms] ─┴─┬────────────────────
                             │
Layer 2:
  Analytics_init(bg) [100ms] ┘

Critical path: Log(30) + Crash(50) + Analytics(100) = 180ms
Parallel savings: 200ms → 180ms ≈ 10%
```

---

## Performance Tracing

```swift
public final class StartupTracer {
    public func report() -> StartupReport
}

public struct StartupReport: Sendable {
    public let totalDuration: Duration
    public let initDuration: Duration
    public let startDuration: Duration
    public let criticalPath: [Span]
    public let parallelSavings: Double
    public let bottlenecks: [Span]
}
```

Usage:

```swift
Engine.delegate = self
try await Engine.run(config: StartupConfig(enableTracing: true))

// In delegate:
func startupDidComplete(with report: StartupReport) {
    print("总耗时: \(report.totalDuration)")
    print("关键路径: \(report.criticalPath)")
    print("瓶颈: \(report.bottlenecks)")
}
```

---

## Migration Guide

### Step 1: Bridge priority → DAG (zero code change)

```swift
// Before
ServiceFactory.start()

// After
let graph = DependencyGraph.fromPriorityModules(ServiceFactory.registeredModules)
try await Engine.run(graph: graph)
```

### Step 2: Migrate individual modules

```swift
// Before
class LogModule: KFModule {
    var priority: Int { 100 }
    func register() { ServiceFactory.register(KFLogger.self) { LogService() } }
}

// After
@Module(depends: [])
final class LogModule: ModuleProtocol {
    func performInit() async {
        ServiceFactory.register(KFLogger.self) { LogService() }
    }
}
```

### Step 3: Full migration

```swift
// Before
ServiceFactory.register(module: A)
ServiceFactory.register(module: B)
ServiceFactory.start()

// After
try await Engine.run()
```

---

## Comparison with Industry

| 能力 | KFService v2 | KFService v3 (DAG) | BeeHive | ByteDance | Needle |
|---|---|---|---|---|---|
| DAG 依赖解析 | ❌ | ✅ Kahn's + Tarjan's | ❌ priority | ✅ | ✅ compile-time |
| 并行初始化 | ❌ serial | ✅ 同层并行 | ✅ manual async | ✅ | ❌ |
| 循环依赖检测 | ❌ | ✅ Tarjan's SCC | ❌ | ✅ | ✅ compile-time |
| MainActor 隔离 | ❌ | ✅ tri-state enum | ❌ | ✅ | ❌ |
| 超时降级 | ❌ | ✅ | ❌ | ❌ | ❌ |
| 性能追踪 | ❌ | ✅ StartupTracer | ❌ | ✅ | ❌ |
| 关键路径分析 | ❌ | ✅ DFS 回溯 | ❌ | ❌ | ❌ |
| 外部依赖 | 0 | 0 | 0 | ~5k | ~10k |
| Invasiveness | Low | Low | Medium | Medium | High |

---

## Full API Reference

### Engine

| Method | Description |
|---|---|
| `Engine.run()` | Start all modules (v2 compatible) |
| `Engine.run(graph:config:)` | Start with DAG |
| `Engine.delegate` | Startup delegate |

### ServiceFactory

| Method | Description |
|---|---|
| `ServiceFactory.register(_:factory:)` | Register a service |
| `ServiceFactory.resolve<T>(_) -> T` | Resolve service instance |
| `ServiceFactory.resolveOptional<T>(_) -> T?` | Safe resolve |
| `ServiceFactory.warmup<T>(_:)` | Warmup a service |
| `ServiceFactory.preload(_:)` | Batch warmup |
| `ServiceFactory.register(module:)` | Register a module (KFModule) |
| `ServiceFactory.start()` | Start all registered modules |
| `ServiceFactory.shutdown()` | Shutdown all modules |
| `ServiceFactory.on<T>(_:handler:) -> KFEventToken` | Subscribe to event |
| `ServiceFactory.emit<T>(_:)` | Emit event |
| `ServiceFactory.registeredServices` | List of registered services |
| `ServiceFactory.resetAll()` | Reset all |

### StartupScheduler

| Method | Description |
|---|---|
| `StartupScheduler(config:)` | Create scheduler |
| `executeLayers(_:stage:)` | Execute layered scheduling |

### DependencyGraph

| Method | Description |
|---|---|
| `DependencyGraph { }` | DSL builder |
| `graph.detectCycles() -> [[ModuleID]]` | Tarjan's cycle detection |
| `graph.topologicalSort() -> [[ModuleNode]]` | Kahn's topological sort |
| `graph.validate()` | Validate graph |
| `DependencyGraph.fromPriorityModules(_:)` | Bridge utility |

---

## Thread Safety

- `ServiceFactory` is thread-safe (backed by `NSLock`)
- `StartupScheduler` is `@MainActor`-isolated
- Background modules use `TaskGroup` + `AsyncSemaphore` for concurrency control
- DAG validation and sorting are value-type operations, naturally thread-safe

---

## License

KernelFlux Internal - MIT License
