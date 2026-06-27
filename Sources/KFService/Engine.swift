import Foundation

/// Engine — KFService 的门面层。
///
/// 聚合 `ServiceFactory`（服务容器）和 `StartupScheduler`（启动调度），
/// 提供简洁的一行启动 API。
///
/// ```swift
/// // 极简启动
/// try await Engine.run()
///
/// // 带配置
/// try await Engine.run(config: StartupConfig(maxBackgroundConcurrency: 4))
///
/// // 带监听
/// Engine.delegate = self
/// try await Engine.run()
/// ```
public enum Engine {

    /// 启动委托
    public weak static var delegate: StartupDelegate?

    /// 启动配置
    public struct Config {
        public var maxBackgroundConcurrency: Int = 4
        public var mainActorTimeout: TimeInterval = 0.5
        public var enableTracing: Bool = false

        public init(
            maxBackgroundConcurrency: Int = 4,
            mainActorTimeout: TimeInterval = 0.5,
            enableTracing: Bool = false
        ) {
            self.maxBackgroundConcurrency = maxBackgroundConcurrency
            self.mainActorTimeout = mainActorTimeout
            self.enableTracing = enableTracing
        }
    }

    /// 启动所有已注册模块（v2 兼容模式）
    public static func run() async throws {
        delegate?.startupDidUpdatePhase(.startupStarted)
        ServiceFactory.start()
        delegate?.startupDidUpdatePhase(.startupCompleted)
    }

    /// 启动所有已注册模块（v2 + 配置 + 委托）
    public static func run(
        config: Config = .init(),
        delegate: StartupDelegate? = nil
    ) async throws {
        if let delegate { Engine.delegate = delegate }
        delegate?.startupDidUpdatePhase(.startupStarted)
        ServiceFactory.start()
        delegate?.startupDidUpdatePhase(.startupCompleted)
        if config.enableTracing {
            let report = StartupTracer().report()
            delegate?.startupDidComplete(with: report)
        }
    }

    /// 使用 DAG 图启动（v3 模式）
    @MainActor
    public static func run(graph: DependencyGraph, config: Config = .init()) async throws {
        delegate?.startupDidUpdatePhase(.validating)
        let cycles = graph.detectCycles()
        if !cycles.isEmpty {
            let error = StartupError.cycleDetected(cycles)
            delegate?.startupDidFail(with: error)
            throw error
        }

        delegate?.startupDidUpdatePhase(.sorting)
        let layers = try graph.topologicalSort()

        let scheduler = StartupScheduler(config: .init(
            maxBackgroundConcurrency: config.maxBackgroundConcurrency
        ))

        delegate?.startupDidUpdatePhase(.executingInit)
        try await scheduler.executeLayers(layers, stage: .initialization)

        delegate?.startupDidUpdatePhase(.executingStart)
        try await scheduler.executeLayers(layers, stage: .start)

        delegate?.startupDidUpdatePhase(.startupCompleted)

        if config.enableTracing {
            let report = scheduler.tracer.report()
            delegate?.startupDidComplete(with: report)
        }
    }
}

// MARK: - Startup Phase

/// 启动阶段
public enum StartupPhase: Sendable {
    case startupStarted
    case validating
    case sorting
    case executingInit
    case executingStart
    case startupCompleted
}

// MARK: - Startup Error

/// 启动错误
public enum StartupError: Error, Sendable {
    case cycleDetected([[ModuleID]])
    case missingDependency(ModuleID, ModuleID)
    case timeout(ModuleID, TimeInterval)
    case initFailed(ModuleID, Error)
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
