# KFService

轻量级、协议驱动的 iOS 服务管理器 —— 依赖注入、模块生命周期、系统事件分发、网络状态监测、类型安全 EventBus。零第三方依赖。

核心理念：**显式优于魔法** —— 无代码生成、无运行时扫描、无注解处理。

[English](README.md)

## 目录

- [安装](#安装)
- [设计理念](#设计理念)
- [核心概念](#核心概念)
- [服务注册与获取](#服务注册与获取)
- [模块系统与生命周期](#模块系统与生命周期)
- [系统事件监听](#系统事件监听)
- [网络状态监测](#网络状态监测)
- [EventBus](#eventbus)
- [线程安全](#线程安全)
- [完整 API 参考](#完整-api-参考)
- [集成指南](#集成指南)
- [许可证](#许可证)

## 安装

**Swift Package Manager**

```
https://github.com/kernelflux/kfservice.git
```

或在 `Package.swift` 中添加：

```swift
.package(url: "https://github.com/kernelflux/kfservice.git", from: "1.0.0")
```

在 target 依赖中添加 `KFService`。最低支持 iOS 12.0。

> `Network.framework` 由包清单自动链接。

---

## 设计理念

### 为什么是 Service Locator 而非 DI Container

主流 iOS DI 框架（Swinject、Typhoon、DIP）采用容器模式 —— 注册类型后，容器通过构造器或属性注入自动构建对象图。这通常需要：

- **代码生成**（Swinject + SwinjectAutoregistration，Android 的 Hilt/Koin）
- **运行时反射**（DIP、旧版 Typhoon）
- **复杂的解析器链** 来满足构造参数依赖

KFService 选择 Service Locator 路线。原因：

1. **SDK 级的简单性** —— 目标用户是基础组件（日志、KV 存储、崩溃上报），而非应用层 DI。这些组件很少有深层依赖树；它们需要的是*发现*，而非*构建*。

2. **显式控制** —— 工厂闭包由开发者手写，初始化顺序和配置在调用处一目了然。不存在嵌套依赖的"魔法"解析。

3. **运行时灵活性** —— 为同一协议注册新工厂会立即替换缓存实例。无需重建容器即可支持 A/B 测试、功能开关和运行时覆盖。

4. **零编译耗时** —— 无代码生成，编译速度不受影响。

### 架构总览

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
│  │  系统事件                      │               │
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

**5 个源文件，约 400 行代码。** 每个子系统自包含于单一文件。

---

## 核心概念

### 注册键（Key）

服务类型通过 `String(reflecting:)` 标识，它生成完整限定类型名（模块 + 类型名）。这意味着 `MyApp.KFLogger` 和 `MyFramework.KFLogger` 是不同的键 —— 不同模块间不会意外冲突。

```swift
private struct Key: Hashable {
    let label: String
    init<T>(_ type: T.Type) { self.label = String(reflecting: type) }
}
```

### 工厂闭包与实例缓存

每个注册存储的是一个 `() -> T` 工厂闭包，而非实例本身。首次 `resolve()` 时调用工厂，结果缓存在 `instances` 字典中，后续 resolve 直接返回缓存。**默认懒加载** —— 从未被 resolve 的服务永远不会被构造。

对已注册的类型调用 `register()` 注册新工厂会清除缓存实例，下次 `resolve()` 使用新工厂构造新实例。这是运行时覆盖（A/B 测试、Mock 注入）的机制。

---

## 服务注册与获取

### 基本注册

```swift
// 协议
protocol KVStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

// 实现
class KFKVDefault: KVStore { ... }

// 注册
KFServiceManager.register(KVStore.self) { KFKVDefault() }
```

工厂闭包是 `@escaping` 的 —— 构造被推迟到首次 resolve。

### 获取实例

```swift
// 未注册时 fatalError（严格模式，基础设施服务应在启动时快速失败）
let store = KFServiceManager.resolve(KVStore.self)

// 未注册时返回 nil（用于可选服务，如埋点）
let tracker = KFServiceManager.resolveOptional(Analytics.self)

// 带默认值 —— 不抛 fatalError，方便测试
let cache = KFServiceManager.resolve(CacheService.self, default: MemoryCache())
```

`resolve()` 刻意选择 `fatalError` 而非返回可选值 —— 基础服务缺失说明启动配置有问题，应当在开发阶段尽早暴露。

### 运行时覆盖

```swift
// 注册初始实现
KFServiceManager.register(KVStore.self) { KFKVDefault() }

// 后续覆盖：测试 / A/B 实验 / 应急降级
KFServiceManager.register(KVStore.self) { MockKVStore() }

// 下一次 resolve 返回 MockKVStore
let store = KFServiceManager.resolve(KVStore.self)
```

### 提前初始化

某些服务必须尽早初始化 —— 崩溃上报（捕获早期崩溃）、日志（记录启动日志）、KV 存储（UI 渲染前读取功能开关）。

```swift
// 单个服务
KFServiceManager.warmup(KVStore.self)   // 返回实例

// 批量 —— 调用者通过参数顺序控制初始化顺序
KFServiceManager.preload(KVStore.self, KFLogger.self, KFNetwork.self)
```

`warmup()` 就是带 `@discardableResult` 的 `resolve()`。`preload()` 静默跳过未注册类型 —— 安全调用可选服务。

---

## 模块系统与生命周期

### KFModule 协议

模块将一组相关服务注册封装在一起，并提供生命周期钩子：

```swift
public protocol KFModule {
    var priority: Int { get }       // 默认 100（越小启动越早）
    func register()                 // 模块注册时调用
    func unregister()               // shutdown 时按优先级逆序调用
}
```

### 优先级语义

优先级同时控制**启动顺序**（升序：100 先于 200）和**关闭顺序**（降序：200 先于 100）。确保基础服务先启动、最后卸载。

| 优先级区间 | 典型用途 |
|-----------|---------|
| 0–99 | 平台级：崩溃上报、日志、KV 存储 |
| 100（默认） | 通用基础设施 |
| 101–200 | 功能模块、埋点、网络 |

```swift
struct KFCrashModule: KFModule {
    let priority = 10   // 最早启动 —— 必须最先捕获崩溃

    func register() {
        KFServiceManager.register(KFCrashProtocol.self) { KFCrashDefault.shared }
    }

    func unregister() {
        // 刷盘待上报的崩溃
        KFServiceManager.resolve(KFCrashProtocol.self).sync()
    }
}

struct KFNetworkModule: KFModule {
    let priority = 300  // 晚启动 —— 依赖 KV 读取 base URL 配置

    func register() {
        let baseURL = KFServiceManager.resolve(KVStore.self).string(forKey: "base_url")
        KFServiceManager.register(APIClient.self) { APIClientDefault(baseURL: baseURL!) }
    }
}
```

### 注册

```swift
// 模块立即注册其服务，并被 retain 以接收生命周期回调
KFServiceManager.register(module: KFCrashModule())
KFServiceManager.register(module: KFKVModule())
```

### 启动与关闭

```swift
// 启动：立即初始化所有已注册服务，订阅系统事件，启动网络监测
KFServiceManager.start()

// 优雅关闭：逆优先级 unregister → 清实例 → 清模块 → 清 EventBus → 停网络 → 取消系统事件
KFServiceManager.shutdown()
```

`shutdown()` 保留工厂注册 —— 可以再次调用 `start()` 重新初始化一切。

---

## 系统事件监听

`KFSystemEventObserver` 协议让服务类接收 App 生命周期和网络事件。所有方法均有默认空实现 —— 只覆写需要的即可。

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

### 工作原理

1. `start()` 调用 `subscribeSystemEvents()`，通过 `NotificationCenter` 为 4 个 UIKit 通知添加 block-based 观察者。
2. 通知触发时，`dispatchToObservers` 在 `lock` 保护下对当前所有缓存实例做快照，然后在锁外遍历快照，对遵循 `KFSystemEventObserver` 的实例调用回调。
3. `shutdown()` 调用 `unsubscribeSystemEvents()`，逐个移除观察者 token。

通知名在 `Notification.Name.KFSystem` 中定义为原始字符串常量，避免 SPM target 中导入 UIKit。

### 使用

```swift
extension KFLogDefault: KFSystemEventObserver {
    func onEnterBackground() { flush() }
    func onMemoryWarning() { flush() }
}
```

观察者模式意味着**服务自行决定** —— KFServiceManager 不需要知道每个服务的生命周期需求。它仅广播事件，每个服务自行处理。

---

## 网络状态监测

KFServiceManager 使用 `NWPathMonitor`（iOS 12+）监测网络连通性，并将变化分发给 `KFSystemEventObserver` 实例。

### 接口类型

```swift
public enum KFNetworkInterface: Sendable {
    case wifi
    case cellular
    case wired
    case loopback
    case other
}
```

### 去重逻辑

监测器跟踪 `lastNetworkAvailable` 和 `lastNetworkInterface`。每次路径更新：

| 条件 | 分发的事件 |
|------|-----------|
| `无网 → 有网` | `onNetworkAvailable()` |
| `有网 → 无网` | `onNetworkUnavailable()` |
| 接口切换（WiFi ↔ 蜂窝） | `onNetworkInterfaceChanged(_:)` |
| 无变化 | 不分发任何事件 |

这防止了 `NWPathMonitor` 在瞬时网络波动时产生重复的"网络可用"回调。

### 线程模型

监测器运行在 `.global(qos: .default)`。状态更新（`lastNetworkAvailable`、`lastNetworkInterface`）在监测器队列上无锁写入 —— 它们在 `dispatchToObservers` 读取之前已写入，且分发在同一队列上同步发生。

---

## EventBus

服务层内类型安全的发布/订阅机制。适用场景：用户退出登录、认证令牌刷新、权益变更、风险识别触发等。

### 设计要点

| 关注点 | 机制 |
|--------|------|
| 内存安全 | `KFEventToken` 在 `deinit` 时自动取消订阅 —— 杜绝遗漏 handler |
| 性能 | 独立的 `eventLock` 与主 `lock` 分离；锁内快照、锁外调用 |
| 类型安全 | 事件按 `ObjectIdentifier(T.self)` 索引 —— 无字符串事件名 |
| 线程 | 回调在**发送线程**执行（无隐式队列跳转） |

### 订阅

```swift
// 定义事件
struct UserLoggedOut {
    let timestamp: Date
}

// 订阅 —— 持有 token
private var tokens: [KFEventToken] = []

tokens.append(KFServiceManager.on(UserLoggedOut.self) { event in
    // 清除用户缓存
    imageCache.removeAll()
    // 回调在 emit() 的调用线程执行
})
```

### 发送

```swift
KFServiceManager.emit(UserLoggedOut(timestamp: Date()))
```

### 取消订阅

三种路径：

```swift
// 1. 自动 —— token 释放时（owner deinit 或置 nil）
token = nil

// 2. 显式 —— 保留属性但立即取消
token.cancel()

// 3. 批量 —— shutdown() 清除所有 handler
```

### KFEventToken 内部实现

Token 仅存储一个 `() -> Void` 闭包，捕获的是 handler ID，而非 handler 本身。`deinit` 时获取 `eventLock`，按 ID 从 `eventHandlers` 字典中移除 handler，并清理空条目。每次取消 O(n)（n 为该事件类型的 handler 数量）—— 可接受，因为取消频率远低于发送频率。发送是 O(1) 快照。

---

## 线程安全

KFServiceManager 使用两把独立锁以最小化竞争：

| 锁 | 保护对象 | 热路径 |
|----|---------|--------|
| `lock` | `factories`、`instances`、`modules` | `resolve()` —— 调用频繁 |
| `eventLock` | `eventHandlers` | `emit()` —— 业务事件触发 |

### Resolve 热路径

```
resolve()
  lock.lock()
  命中缓存 → 直接返回   ← 热路径：O(1)，持锁纳秒级
  lock.unlock()
  factory()             ← 构造在锁外执行
  lock.lock()
  缓存实例
  lock.unlock()
```

常见情况（已缓存）是锁内一次字典查找 —— 竞争最小化。

### 快照-分发模式

系统事件和 EventBus 均使用**快照-分发**模式：

```
lock.lock()
snapshot = collection.copy()
lock.unlock()

for item in snapshot {
    callback(item)       // handler 在锁外执行 —— 不会死锁
}
```

这意味着回调内部再次调用 KFServiceManager（如 resolve 另一个服务）是安全的 —— `NSLock` 不可重入，但回调执行时锁未被持有，不会死锁。

---

## 完整 API 参考

### 注册与获取

| 方法 | 说明 |
|------|------|
| `register(_:factory:)` | 为协议类型注册工厂闭包。替换已有工厂，清除缓存实例 |
| `resolve(_:)` | 获取或创建缓存实例。未注册时 `fatalError` |
| `resolveOptional(_:)` | 获取或创建缓存实例。未注册时返回 `nil` |
| `resolve(_:default:)` | `@autoclosure` 参数，未注册时返回默认值 |

### 模块生命周期

| 方法 | 说明 |
|------|------|
| `register(module:)` | 注册 `KFModule` —— 调用 `module.register()`，retain 以接收生命周期回调 |
| `start()` | 立即初始化所有注册服务；订阅系统事件；启动网络监测 |
| `shutdown()` | 逆优先级卸载；清除实例、模块、EventBus handler |

### 编排

| 方法 | 说明 |
|------|------|
| `warmup(_:)` | 立即初始化并缓存单个服务。`@discardableResult` |
| `preload(_:)` | 按调用者指定顺序批量初始化。静默跳过未注册类型 |
| `isRegistered(_:)` | 检查类型是否已注册 |
| `registeredServices` | 已注册类型名的排序列表（调试/自省用） |

### 状态管理

| 方法 | 说明 |
|------|------|
| `reset(_:)` | 清除某服务的缓存实例。下次 `resolve()` 重建 |
| `resetAll()` | 清除所有注册和缓存实例 |

### EventBus

| 方法 | 说明 |
|------|------|
| `on(_:handler:) -> KFEventToken` | 按类型订阅事件。持有 token 保持订阅状态 |
| `emit(_:)` | 向当前线程上的所有订阅者发送事件 |

---

## 集成指南

### 典型启动流程

```swift
// AppDelegate.application(_:didFinishLaunchingWithOptions:)

// 阶段 1：按依赖顺序注册模块
KFServiceManager.register(module: KFCrashModule())     // priority 10
KFServiceManager.register(module: KFKVModule())         // priority 100
KFServiceManager.register(module: KFLogModule())        // priority 200
KFServiceManager.register(module: KFNetworkModule())    // priority 300

// 阶段 2：条件注册或手动覆盖
#if DEBUG
KFServiceManager.register(KVStore.self) { MockKVStore() }
#endif

// 阶段 3：启动服务管理器
KFServiceManager.start()
```

### 关闭（可选）

```swift
// AppDelegate.applicationWillTerminate(_:)
KFServiceManager.shutdown()
```

### 在业务代码中使用服务

```swift
class UserProfileViewController: UIViewController {
    // 必需服务用 resolve() —— 快速失败
    private let logger = KFServiceManager.resolve(KFLogger.self)
    private let store  = KFServiceManager.resolve(KVStore.self)

    // 可选服务用 resolveOptional
    private let analytics = KFServiceManager.resolveOptional(Analytics.self)

    override func viewDidLoad() {
        super.viewDidLoad()
        logger.info("profile loaded")
        analytics?.track(.screenView("profile"))
    }
}
```

### 监听事件

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

    // tokens deinit → 所有 handler 自动移除
}
```

### 测试

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

> 注意：`resetAll()` 仅清除注册，**不会**取消系统事件订阅或停止网络监测。如需完整清理，使用 `shutdown()`。

---

## 源文件结构

```
Sources/KFService/
├── KFServiceManager.swift           — 服务定位、生命周期、系统事件、网络监测、EventBus
├── KFModule.swift                   — KFModule 协议 + register(module:) 扩展
├── KFSystemEventObserver.swift      — 观察者协议 + KFNetworkInterface 枚举
├── KFSystemNotifications.swift      — UIKit 通知名常量（无需 import UIKit）
└── KFEventToken.swift               — 自动取消订阅的事件令牌
```

## 许可证

[MIT](LICENSE) — Copyright (c) 2026 KernelFlux
