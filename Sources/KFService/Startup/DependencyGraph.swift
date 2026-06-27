import Foundation

// MARK: - ModuleID

/// 模块唯一标识，编译期类型安全地从 metatype 构造。
public struct ModuleID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

extension ModuleID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.rawValue = value }
}

extension ModuleID {
    public init(_ type: ModuleProtocol.Type) {
        self.rawValue = "\(type)"
    }
}

// MARK: - ActorRequirement

/// 三态 Actor 隔离声明。
public enum ActorRequirement: Sendable {
    /// 必须在 MainActor 上执行（UIKit 依赖）
    case mainActor
    /// 必须在后台线程执行（耗时计算/I/O）
    case background(DispatchQoS.QoSClass)
    /// 调度器自动决定（默认）
    case automatic
}

// MARK: - ModuleNode

/// DAG 中的一个节点 = 一个启动任务。
public struct ModuleNode: Sendable {
    public let id: ModuleID
    public let dependencies: [ModuleID]
    public let factory: @Sendable () async -> Void
    public let priority: Int
    public let actorRequirement: ActorRequirement
    public let maxExecTime: TimeInterval?

    public init(
        id: ModuleID,
        dependencies: [ModuleID] = [],
        priority: Int = 100,
        actorRequirement: ActorRequirement = .automatic,
        maxExecTime: TimeInterval? = nil,
        factory: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.dependencies = dependencies
        self.priority = priority
        self.actorRequirement = actorRequirement
        self.maxExecTime = maxExecTime
        self.factory = factory
    }
}

// MARK: - DependencyGraph

/// 依赖图：构建 → Tarjan's 验证环 → Kahn's 拓扑排序 → 分层并行。
public struct DependencyGraph: Sendable {
    public private(set) var nodes: [ModuleNode]

    public init(nodes: [ModuleNode] = []) {
        self.nodes = nodes
    }

    public mutating func add(_ node: ModuleNode) {
        nodes.append(node)
    }

    // MARK: 验证

    /// Tarjan's SCC 检测所有环。
    public func detectCycles() -> [[ModuleID]] {
        var index = 0
        var stack: [ModuleID] = []
        var indices: [ModuleID: Int] = [:]
        var lowlink: [ModuleID: Int] = [:]
        var onStack: Set<ModuleID> = Set()
        var cycles: [[ModuleID]] = []

        func strongConnect(_ id: ModuleID) {
            indices[id] = index; lowlink[id] = index; index += 1
            stack.append(id); onStack.insert(id)

            guard let node = nodes.first(where: { $0.id == id }) else { return }
            for dep in node.dependencies {
                if indices[dep] == nil {
                    strongConnect(dep)
                    lowlink[id] = min(lowlink[id]!, lowlink[dep]!)
                } else if onStack.contains(dep) {
                    lowlink[id] = min(lowlink[id]!, indices[dep]!)
                }
            }

            if lowlink[id] == indices[id] {
                var component: [ModuleID] = []
                while let top = stack.last, indices[top]! >= indices[id]! {
                    component.append(stack.removeLast())
                    onStack.remove(top)
                }
                if component.count > 1 { cycles.append(component) }
            }
        }

        for node in nodes where indices[node.id] == nil {
            strongConnect(node.id)
        }
        return cycles
    }

    /// 验证合法性。
    public func validate() throws {
        // 重复 ID
        let ids = nodes.map(\.id)
        let uniqueIDs = Set(ids)
        if ids.count != uniqueIDs.count {
            throw GraphError.duplicateIDs
        }
        // 缺失依赖
        for node in nodes {
            for dep in node.dependencies {
                if !uniqueIDs.contains(dep) {
                    throw GraphError.missingDependency(node.id, dep)
                }
            }
        }
        // 循环依赖
        let cycles = detectCycles()
        if !cycles.isEmpty {
            throw GraphError.cycleDetected(cycles)
        }
    }

    // MARK: 拓扑排序

    /// Kahn's 算法 → 返回分层并行结构。
    public func topologicalSort() throws -> [[ModuleNode]] {
        var inDegree: [ModuleID: Int] = [:]
        var childMap: [ModuleID: [ModuleID]] = [:]

        for node in nodes {
            inDegree[node.id] = inDegree[node.id] ?? 0
            for dep in node.dependencies {
                inDegree[node.id, default: 0] += 1
                childMap[dep, default: []].append(node.id)
            }
        }

        var queue: [ModuleID] = inDegree.filter { $0.value == 0 }.map(\.key)
        var layers: [[ModuleNode]] = []
        var visited: Set<ModuleID> = []

        while !queue.isEmpty {
            let currentLayer = queue
                .compactMap { id in nodes.first { $0.id == id } }
                .sorted { $0.priority < $1.priority }
            layers.append(currentLayer)
            queue.removeAll()

            for nodeID in currentLayer.map(\.id) {
                visited.insert(nodeID)
                for child in childMap[nodeID, default: []] {
                    inDegree[child, default: 1] -= 1
                    if inDegree[child] == 0 {
                        queue.append(child)
                    }
                }
            }
        }

        if visited.count != nodes.count {
            let remaining = Set(nodes.map(\.id)).subtracting(visited)
            throw GraphError.cycleDetected(Array(remaining).map { [$0] })
        }
        return layers
    }
}

// MARK: - GraphError

public enum GraphError: Error, Sendable {
    case duplicateIDs
    case missingDependency(ModuleID, ModuleID)
    case cycleDetected([[ModuleID]])
}

// MARK: - GraphBuilder DSL

@resultBuilder
public enum GraphBuilder {
    public static func buildBlock(_ components: ModuleNode...) -> [ModuleNode] {
        components
    }
}

extension DependencyGraph {
    public init(@GraphBuilder _ build: () -> [ModuleNode]) {
        self.nodes = build()
    }
}
