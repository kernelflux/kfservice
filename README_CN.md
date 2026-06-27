# KFService

轻量级服务容器 + DAG 启动调度框架，零外部依赖。

借鉴阿里 BeeHive（3 层分离）、字节跳动抖音（DAG 并行调度）、美团 Kylin（T0 计时）、腾讯微信（超时降级）等行业实践。

[English Documentation](README.md)

---

## 快速开始

### 1. 定义模块

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
```

### 2. 一行启动

```swift
try await Engine.run()
```

### 3. 使用服务

```swift
let log = ServiceFactory.resolve(KFLogger.self)
log.info("App started")
```

---

## 架构

### 3 层分离 + Facade

```
Engine（门面）
├── ServiceFactory（服务容器）
│   ├── register / resolve
│   ├── warmup / preload
│   └── EventBus
└── StartupScheduler（启动调度）
    ├── DependencyGraph（DAG + Kahn's + Tarjan's）
    └── StartupTracer（性能追踪）
```

### 目录结构

```
Sources/KFService/
├── Engine.swift                  Facade
├── Core/
│   ├── ServiceFactory.swift      服务容器
│   ├── ModuleProtocol.swift      模块协议
│   ├── KFEventToken.swift        事件令牌
│   ├── KFSystemEventObserver.swift
│   └── KFSystemNotifications.swift
└── Startup/
    ├── DependencyGraph.swift      DAG
    ├── StartupScheduler.swift     调度器
    └── StartupTracer.swift        追踪
```

---

## 详细文档

详见 [English README](README.md) 中的以下章节：

- [Quick Start](README.md#quick-start)
- [Architecture](README.md#architecture)
- [Core Types](README.md#core-types)
- [Module Definition](README.md#module-definition)
- [Service Registration & Resolution](README.md#service-registration--resolution)
- [DAG Scheduling](README.md#dag-scheduling)
- [Threading Model](README.md#threading-model)
- [Performance Tracing](README.md#performance-tracing)
- [Migration Guide](README.md#migration-guide)
- [Comparison with Industry](README.md#comparison-with-industry)
- [Full API Reference](README.md#full-api-reference)
- [License](README.md#license)

---

## License

KernelFlux Internal — MIT License
