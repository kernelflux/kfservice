import Foundation

/// Engine — KFService 的门面层。
///
/// 聚合 `ServiceContainer`（DI）、`ServiceEventBus`（事件总线）、`ServiceRuntime`（生命周期）
/// 和 `StartupScheduler`（启动调度），提供基于 `StartupTask` 的启动编排。
///
/// ```swift
/// // 1. 宿主注册服务
/// ServiceContainer.shared.register(KVStore.self) { KFKVDefault() }
/// ServiceContainer.shared.register(KFLogger.self) { KFLogDefault() }
///
/// // 2. 创建 task，传入宿主配置
/// let tasks: [any StartupTask] = [
///     KFKVStartupTask(),
///     KFLogStartupTask(config: KFLogConfig(logDir: dir, namePrefix: "App", level: .verbose)),
/// ]
///
/// // 3. 启动 — 自动 DAG → 拓扑排序 → 分层并行
/// try await Engine.run(tasks: tasks)
///
/// // 带配置和监听
/// try await Engine.run(tasks: tasks, config: .init(enableTracing: true), delegate: self)
/// ```
public enum Engine {

    /// 启动委托
    public weak static var delegate: StartupDelegate?

    /// 启动配置
    public struct Config {
        public var maxBackgroundConcurrency: Int = 4
        public var enableTracing: Bool = false

        public init(
            maxBackgroundConcurrency: Int = 4,
            enableTracing: Bool = false
        ) {
            self.maxBackgroundConcurrency = maxBackgroundConcurrency
            self.enableTracing = enableTracing
        }
    }

    // MARK: - StartupTask API

    /// Run startup tasks with dependency ordering and parallel scheduling.
    ///
    /// Execution:
    /// 1. Validate unique task identifiers
    /// 2. Build DAG from `StartupTask.dependencies` — cycle detection, missing dep validation
    /// 3. Topological sort → layers (parallel within each layer)
    /// 4. Execute `run()` on each task
    @MainActor
    public static func run(
        tasks: [any StartupTask],
        config: Config = .init(),
        delegate: StartupDelegate? = nil
    ) async throws {
        if let delegate { Engine.delegate = delegate }
        let engineDelegate = Engine.delegate

        guard !tasks.isEmpty else {
            engineDelegate?.startupDidUpdatePhase(.startupCompleted)
            return
        }

        // Validate unique identifiers
        let ids = tasks.map(\.identifier)
        let uniqueIDs = Set(ids)
        guard ids.count == uniqueIDs.count else {
            let error = StartupError.duplicateTaskIDs
            engineDelegate?.startupDidFail(with: error)
            throw error
        }

        // Build task map
        var taskMap: [String: any StartupTask] = [:]
        for task in tasks { taskMap[task.identifier] = task }

        // Phase 1: Build DAG
        engineDelegate?.startupDidUpdatePhase(.validating)
        var graph = DependencyGraph()

        for task in tasks {
            let deps = task.dependencies.map { ModuleID($0) }
            let node = ModuleNode(
                id: ModuleID(task.identifier),
                dependencies: deps,
                priority: task.priority,
                actorRequirement: task.actorRequirement,
                factory: { @Sendable in }
            )
            graph.add(node)
        }

        // Cycle detection
        let cycles = graph.detectCycles()
        if !cycles.isEmpty {
            let error = StartupError.cycleDetected(cycles)
            engineDelegate?.startupDidFail(with: error)
            throw error
        }

        // Missing dependency check
        try graph.validate()

        // Topological sort → layers
        engineDelegate?.startupDidUpdatePhase(.sorting)
        let layers = try graph.topologicalSort()

        let schedulerConfig = StartupConfig(maxBackgroundConcurrency: config.maxBackgroundConcurrency)
        let scheduler = StartupScheduler(config: schedulerConfig)

        // Phase 2: Execute run() — topological order, parallel within layers
        engineDelegate?.startupDidUpdatePhase(.executingInit)

        var allFailures: [StartupFailure] = []

        for (index, layer) in layers.enumerated() {
            let runNodes: [ModuleNode] = layer.compactMap { node in
                guard let task = taskMap[node.id.rawValue] else { return nil }
                return ModuleNode(
                    id: node.id,
                    dependencies: node.dependencies,
                    priority: node.priority,
                    actorRequirement: node.actorRequirement,
                    factory: { try await task.run() }
                )
            }
            if !runNodes.isEmpty {
                let failures = await scheduler.executeLayer(runNodes, layerIndex: index, stage: .initialization)
                allFailures.append(contentsOf: failures)
            }
        }

        engineDelegate?.startupDidUpdatePhase(.startupCompleted)

        if config.enableTracing {
            let report = scheduler.tracer.report(failures: allFailures)
            engineDelegate?.startupDidComplete(with: report)
        }
    }

    /// Run startup tasks from modules. Convenience overload that flatMaps
    /// `StartupModule.tasks` and delegates to `run(tasks:config:delegate:)`.
    @MainActor
    public static func run(
        modules: [any StartupModule],
        config: Config = .init(),
        delegate: StartupDelegate? = nil
    ) async throws {
        let tasks = modules.flatMap { $0.tasks }
        try await run(tasks: tasks, config: config, delegate: delegate)
    }
}

// MARK: - Startup Phase

/// 启动阶段
public enum StartupPhase: Sendable {
    case validating
    case sorting
    case executingInit
    case startupCompleted
}

// MARK: - Startup Error

/// 启动错误
public enum StartupError: Error, Sendable {
    case cycleDetected([[ModuleID]])
    case missingDependency(ModuleID, ModuleID)
    case timeout(ModuleID, TimeInterval)
    case initFailed(ModuleID, Error)
    case duplicateTaskIDs
}

// MARK: - StartupDelegate

/// 启动委托协议
public protocol StartupDelegate: AnyObject {
    func startupDidUpdatePhase(_ phase: StartupPhase)
    func startupDidComplete(with report: StartupReport)
    func startupDidFail(with error: Error)
}

public extension StartupDelegate {
    func startupDidUpdatePhase(_ phase: StartupPhase) {}
    func startupDidComplete(with report: StartupReport) {}
    func startupDidFail(with error: Error) {}
}
