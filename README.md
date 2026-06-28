# KFService

A lightweight service container + DAG-based startup scheduler. Zero external dependencies, iOS 16+.

## Core Types

| Type | Role |
|------|------|
| `ServiceContainer` | Thread-safe DI container — register, resolve, scopes, child containers |
| `ServiceAssembly` | Group registrations by package, install with `container.install(MyAssembly())` |
| `ServiceEventBus` | Event pub/sub with dispatch modes and sticky events |
| `@Inject` | Property wrapper for service resolution |
| `DependencyGraph` | DAG builder — Kahn's topological sort, Tarjan's SCC cycle detection |
| `ModuleNode` | DAG node representing a startup task |
| `StartupTask` | Protocol for an async startup unit |
| `StartupModule` | Group tasks by package, run with `Engine.run(modules:)` |
| `Engine` | Facade — builds DAG from tasks, validates, executes layered parallel schedule |
| `StartupTracer` | Performance tracing — critical path, parallel savings, bottlenecks |

## Quick Start

### 1. Define services

```swift
public protocol KVStore: AnyObject {
    func string(forKey: String) -> String?
    func set(_ value: String, forKey: String) -> Bool
}
```

### 2. Register via Assembly (in package)

```swift
import KFService
import KFKVAPI

public struct KFKVAssembly: ServiceAssembly {
    public init() {}
    public func assemble(container: ServiceContainer) {
        container.register(KVStore.self) { KFKVDefault() }
    }
}
```

### 3. Define startup tasks (in package)

```swift
public struct KFKVStartupModule: StartupModule {
    private let config: KFKVConfig
    public var tasks: [any StartupTask] { [KFKVStartupTask(config: config)] }
    public init(config: KFKVConfig) { self.config = config }
}
```

### 4. Wire everything in the host App

```swift
@main
struct App: App {
    init() {
        ServiceContainer.shared.install([
            KFKVAssembly(),
            KFLogAssembly(),
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    try? await Engine.run(modules: [
                        KFKVStartupModule(config: .init(mmapID: "MyApp")),
                        KFLogStartupModule(config: .init(logDir: logDir, namePrefix: "MyApp")),
                    ])
                }
        }
    }
}
```

## DI Container

### Registration

```swift
let container = ServiceContainer.shared

// Basic — singleton scope (default)
container.register(KVStore.self) { KFKVDefault() }

// Named registration
container.register(KFLogger.self, name: "console") { KFConsoleLogger() }

// With scope
container.register(UserSession.self, scope: .transient) { UserSession() }
container.register(Cache.self, scope: .weak) { Cache() }

// Parameterized factory (1–5 args)
container.register(Printer.self) { (_, tag: String) in Printer(tag: tag) }
```

### Resolution

```swift
// Plain resolve
let kv = try container.resolve(KVStore.self)
let logger = try container.resolve(KFLogger.self, name: "console")

// Parameterized
let printer = try container.resolve(Printer.self, argument: "debug")

// Optional
let optional = container.resolveOptional(KVStore.self) // nil if not registered
```

### Scopes

| Scope | Behavior |
|-------|----------|
| `.singleton` | Cached forever (default) |
| `.transient` | New instance every resolve |
| `.weak` | Cached via weak reference; recreated if deallocated |

### Child Containers

```swift
let userScope = container.newChild()
userScope.register(UserSession.self) { UserSession() }

// Resolve chain: child → parent → grandparent
let session: UserSession = try userScope.resolve()

// Tear down user scope without affecting global singletons
userScope.resetAll()
```

### @Inject Property Wrapper

```swift
struct ContentView: View {
    @Inject(KVStore.self) private var kv

    var body: some View {
        Text(kv.string(forKey: "theme") ?? "")
    }
}
```

### ServiceAssembly

Group registrations so each package ships its own defaults:

```swift
public struct MyAssembly: ServiceAssembly {
    public func assemble(container: ServiceContainer) {
        container.register(MyService.self) { DefaultImpl() }
    }
}
container.install(MyAssembly())
// Host can override before or after — last write wins
container.register(MyService.self) { CustomImpl() }
```

## Event Bus

```swift
// Subscribe (keep token alive to stay subscribed)
let token = ServiceEventBus.shared.on(UserLoggedOut.self) { event in
    print("User logged out at \(event.timestamp)")
}

// Emit
ServiceEventBus.shared.emit(UserLoggedOut())

// Dispatch modes
ServiceEventBus.shared.emit(event, mode: .main)       // async to main queue
ServiceEventBus.shared.emit(event, mode: .background)  // async to background
ServiceEventBus.shared.emit(event, mode: .posting)     // sync on caller thread (default)

// Subscriber-side override — forces main thread delivery
let token = ServiceEventBus.shared.on(String.self, mode: .main) { msg in ... }
```

## Startup Orchestration

### StartupTask

```swift
final class MyTask: BaseStartupTask {
    override var identifier: String { "com.app.my-task" }
    override var dependencies: [String] { ["com.app.log"] }
    override var priority: Int { 100 }           // lower = earlier within layer
    override var maxExecTime: TimeInterval? { 5 } // timeout degradation
    override func run() async throws {
        // startup work
    }
}
```

### Execution Model

```
Phase 1: Validate
  Tarjan's SCC → detect cycles → report and abort if found

Phase 2: Sort
  Kahn's algorithm → layered output [[Layer0], [Layer1], ...]
  Nodes in same layer have no inter-dependencies → parallel safe

Phase 3: Execute
  For each layer:
    MainActor tasks run serially (UIKit safety)
    Background tasks run in TaskGroup (parallel, bounded by semaphore)
    Timeout per node → degradation (skip dependents, continue others)
```

### StartupReport

```swift
public struct StartupReport: Sendable {
    public let totalDuration: Duration
    public let criticalPath: [Span]      // longest path through the DAG
    public let parallelSavings: Duration // serial total − critical path
    public let failures: [StartupFailure]
    public let spans: [Span]             // per-node timing
    public let layers: Int
}
```

## DependencyGraph

```swift
var graph = DependencyGraph()
graph.add(ModuleNode(id: "Log", factory: logTask.run))
graph.add(ModuleNode(id: "Crash", dependencies: ["Log"], factory: crashTask.run))

// Validate
try graph.validate()                              // throws on cycles, duplicates, missing deps
let cycles = graph.detectCycles()                 // Tarjan's SCC — includes self-cycles

// Sort
let layers = try graph.topologicalSort()          // Kahn's algorithm
```

## Thread Safety

| Component | Mechanism |
|-----------|-----------|
| `ServiceContainer` | `OSAllocatedUnfairLock<State>` |
| `ServiceEventBus` | `OSAllocatedUnfairLock<EventBusState>` |
| `StartupScheduler` | `@MainActor` + `OSAllocatedUnfairLock` for degradation state |
| `StartupTracer` | `OSAllocatedUnfairLock<TracerState>` |
| `DependencyGraph` | Value type, naturally thread-safe |

## File Structure

```
Sources/KFService/
├── Engine.swift
├── Core/
│   ├── ServiceContainer.swift    DI container + scopes + children
│   ├── ServiceEventBus.swift     Event pub/sub with dispatch modes
│   ├── Inject.swift              @Inject property wrapper
│   ├── ServiceAssembly.swift     Assembly protocol
│   └── StartupModule.swift       StartupModule + AdHocStartupModule
└── Startup/
    ├── StartupTask.swift         StartupTask + BaseStartupTask protocols
    ├── DependencyGraph.swift     DAG + Kahn's + Tarjan's
    ├── StartupScheduler.swift    Layered parallel scheduler
    └── StartupTracer.swift       Performance tracing + report
```

## Error Types

```swift
public enum ServiceError: Error {
    case notRegistered(String)
    case typeMismatch(String)
    case weakScopeRequiresReferenceType(String)
}

public enum GraphError: Error {
    case duplicateIDs
    case missingDependency(ModuleID, ModuleID)
    case cycleDetected([[ModuleID]])
}

public enum StartupError: Error {
    case duplicateTaskIDs([String])
    case initFailed(ModuleID, Error)
}
```

## Requirements

- iOS 16.0+ / macOS 13.0+
- Swift 5.9+
- No external dependencies

## License

KernelFlux Internal — MIT License
