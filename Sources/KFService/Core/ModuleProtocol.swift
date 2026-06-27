import Foundation

/// 模块协议 — 模块作者只需实现 performInit()，声明依赖即可。
///
/// 依赖通过 `ModuleID(Type.self)` 编译期类型安全声明，
/// Engine 自动完成 DAG 构建 → 拓扑排序 → 分层并行启动。
///
/// ```swift
/// final class LogModule: ModuleProtocol {
///     static var dependencies: [ModuleID] { [] }
///     func performInit() async {
///         ServiceFactory.register(KFLogger.self) { LogService() }
///     }
/// }
/// ```
public protocol ModuleProtocol: AnyObject {
    /// 显式声明依赖的模块 ID（编译期类型安全）
    static var dependencies: [ModuleID] { get }

    /// 初始化逻辑（异步 — 由 Engine 调度）
    func performInit() async
}

public extension ModuleProtocol {
    static var dependencies: [ModuleID] { [] }
    func performInit() async {}
}

/// 同步注册辅助 — 用于同步上下文（如 App.init()）
public struct ModuleRegister {
    public static func run(_ modules: ModuleProtocol...) {
        for module in modules {
            // Modules that use ServiceFactory.register() internally are
            // synchronous — performInit only exists for Engine compatibility.
        }
    }
}
