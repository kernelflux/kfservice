# KFService

轻量级服务容器 + DAG 启动调度框架，零外部依赖。

```
Engine（门面层）
├── ServiceFactory（服务容器层）
└── StartupScheduler（启动调度层）
    ├── DependencyGraph（DAG + Kahn's + Tarjan's）
    └── StartupTracer（性能追踪）
```

借鉴阿里 BeeHive（3 层分离）、字节跳动抖音（DAG 并行调度）、美团 Kylin（T0 计时）、腾讯微信（超时降级）等行业实践。

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
@Module(depends: [])                    // 无依赖
final class LogModule: ModuleProtocol {
    func performInit() async {
        ServiceFactory.register(KFLogger.self) { LogService() }
    }
}

@Module(depends: [LogModule.self])      // 编译期类型安全
final class CrashModule: ModuleProtocol {
    func performInit() async {
        ServiceFactory.register(KFCrashService.self) { CrashService() }
    }
}

@Module(depends: [LogModule.self], on: .background(.utility))
final class AnalyticsModule: ModuleProtocol {
    func performInit() async {
        await preloadDatasets()  // 后台初始化，不阻塞主线程
    }
}

@Module(depends: [], lazy: true)        // 懒加载
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

**3 行定义模块 → 1 行启动 → 随处使用。**

---

## Architecture

### 3-Layer Separation + Facade

```
┌──────────────────────────────────────────────────────────┐
│  Facade: Engine                                           │
│  Engine.run() → 聚合 ServiceFactory + StartupScheduler    │
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
│   ├── ServiceFactory.swift      服务容器
│   ├── ModuleProtocol.swift      模块协议
│   ├── KFEventToken.swift        事件订阅令牌
│   ├── KFSystemEventObserver.swift 系统事件
│   └── KFSystemNotifications.swift 通知映射
└── Startup/
    ├── DependencyGraph.swift      DAG + Kahn's + Tarjan's
    ├── StartupScheduler.swift     分层调度器
    └── StartupTracer.swift        性能追踪
```

---

## Core Types

### ModuleID

```swift
public struct ModuleID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String)
    public init(_ type: ModuleProtocol.Type)  // 编译期类型安全
}
```

### ActorRequirement — 三态线程声明

```swift
public enum ActorRequirement: Sendable {
    case mainActor                          // 必须 MainActor
    case background(DispatchQoS.QoSClass)   // 必须后台
    case automatic                          // 调度器决定（默认）
}
```

### ModuleNode — DAG 节点

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
    /// 构建 DSL
    public init(@GraphBuilder _ build: () -> [ModuleNode])

    /// Tarjan's SCC 检测循环依赖
    public func detectCycles() -> [[ModuleID]]

    /// Kahn's 拓扑排序 → 分层并行结构
    public func topologicalSort() throws -> [[ModuleNode]]

    /// 验证合法性
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
| `depends` | `[ModuleProtocol.Type]` | `[]` | 编译期类型安全的依赖声明 |
| `on` | `ActorRequirement` | `.automatic` | 线程要求 |
| `lazy` | `Bool` | `false` | 是否懒加载（首次使用时才初始化） |
| `maxExecTime` | `TimeInterval?` | `nil` | 超时降级阈值（腾讯模式） |

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
Phase 1: 验证
  Tarjan's SCC → 检测强连通分量
  如果有环 → 报告循环依赖，拒绝启动

Phase 2: 排序
  Kahn's Algorithm → 分层结构 [[Layer0], [Layer1], ...]
  同层无依赖，可并行

Phase 3: 执行
  for each layer:
    Step 1: MainActor 模块串行（美团模式）
    Step 2: 后台模块并行（字节模式）
    Step 3: 超时降级（腾讯模式）
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
  │ Step 1: MainActor 串行执行              │  ← 美团模式
  │  同层中按 priority 排序，逐个执行        │     避免 main/bg 竞争
  ├────────────────────────────────────────┤
  │ Step 2: 后台模块并行执行                 │  ← 字节模式
  │  withThrowingTaskGroup 全并行           │
  │  AsyncSemaphore(max: 4) 控制上限        │
  ├────────────────────────────────────────┤
  │ Step 3: 超时降级                        │  ← 腾讯模式
  │  模块超 maxExecTime → 抛出 timeout     │
  └────────────────────────────────────────┘
```

### Visualization

```
Layer 0:
  Log_init(main) [30ms] ───────────────────────────

Layer 1 (main串行 ‖ bg并行):
  KV_init(bg)   [20ms] ────┐
  Crash_init(main) [50ms] ─┴─┬────────────────────
                             │
Layer 2:
  Analytics_init(bg) [100ms] ┘

关键路径: Log(30) + Crash(50) + Analytics(100) = 180ms
并行节省: 200ms → 180ms ≈ 10%
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
| DAG 依赖解析 | ❌ | ✅ Kahn's + Tarjan's | ❌ priority | ✅ | ✅ 编译期 |
| 并行初始化 | ❌ 串行 | ✅ 同层并行 | ✅ 手动 async | ✅ | ❌ |
| 循环依赖检测 | ❌ | ✅ Tarjan's SCC | ❌ | ✅ | ✅ 编译期 |
| MainActor 隔离 | ❌ | ✅ 三态枚举 | ❌ | ✅ | ❌ |
| 超时降级 | ❌ | ✅ | ❌ | ❌ | ❌ |
| 性能追踪 | ❌ | ✅ StartupTracer | ❌ | ✅ | ❌ |
| 关键路径分析 | ❌ | ✅ DFS 回溯 | ❌ | ❌ | ❌ |
| 外部依赖 | 0 | 0 | 0 | ~5k | ~10k |
| 侵入性 | 低 | 低 | 中 | 中 | 高 |

---

## Full API Reference

### Engine

| Method | Description |
|---|---|
| `Engine.run()` | 启动所有模块（v2 兼容模式） |
| `Engine.run(graph:config:)` | 使用 DAG 启动 |
| `Engine.delegate` | 启动委托 |

### ServiceFactory

| Method | Description |
|---|---|
| `ServiceFactory.register(_:factory:)` | 注册服务 |
| `ServiceFactory.resolve<T>(_) -> T` | 获取服务实例 |
| `ServiceFactory.resolveOptional<T>(_) -> T?` | 安全获取 |
| `ServiceFactory.warmup<T>(_:)` | 预热单个服务 |
| `ServiceFactory.preload(_:)` | 批量预热 |
| `ServiceFactory.register(module:)` | 注册模块（KFModule 兼容） |
| `ServiceFactory.start()` | 启动所有已注册模块 |
| `ServiceFactory.shutdown()` | 关闭所有模块 |
| `ServiceFactory.on<T>(_:handler:) -> KFEventToken` | 订阅事件 |
| `ServiceFactory.emit<T>(_:)` | 发布事件 |
| `ServiceFactory.registeredServices` | 已注册服务列表 |
| `ServiceFactory.resetAll()` | 重置 |

### StartupScheduler

| Method | Description |
|---|---|
| `StartupScheduler(config:)` | 创建调度器 |
| `executeLayers(_:stage:)` | 执行分层调度 |

### DependencyGraph

| Method | Description |
|---|---|
| `DependencyGraph { }` | DSL 构建 |
| `graph.detectCycles() -> [[ModuleID]]` | Tarjan's 环检测 |
| `graph.topologicalSort() -> [[ModuleNode]]` | Kahn's 拓扑排序 |
| `graph.validate()` | 合法性验证 |
| `DependencyGraph.fromPriorityModules(_:)` | bridge 工具 |

---

## Thread Safety

- `ServiceFactory` 全部方法线程安全（内部 `NSLock`）
- `StartupScheduler` 标注 `@MainActor`，调度在 MainActor 上
- 后台模块通过 `TaskGroup` + `AsyncSemaphore` 控制并发
- DAG 验证和排序是值类型操作，天然线程安全

---

## License

KernelFlux Internal — MIT License
