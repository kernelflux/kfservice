// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import os

/// How emitted events are dispatched to subscribers.
public enum EventDispatchMode: Sendable {
    /// Synchronous on the emitting thread (default, matches prior behavior).
    case posting
    /// Asynchronous on the main actor / main queue.
    case main
    /// Asynchronous on a background queue.
    case background
}

/// Per-subscriber thread preference. Overrides the emitter's dispatch mode
/// for this specific handler.
public enum SubscriberThreadMode: Sendable {
    /// Follow the emitter's `EventDispatchMode` (default).
    case posting
    /// Always run this handler on the main queue.
    case main
    /// Always run this handler on a background queue.
    case background
}

/// Lightweight in-app event bus — publish/subscribe with sticky event support.
///
/// Sticky events are held after emission so that late subscribers receive the
/// most recent value immediately on subscription (greenrobot-style).
///
/// ```
/// private var token: KFEventToken?
/// token = bus.on(UserLoggedOut.self) { event in ... }
/// token = bus.on(UserLoggedOut.self, mode: .main, receiveSticky: true) { event in ... }
/// bus.emit(UserLoggedOut(timestamp: Date()), sticky: true)
/// bus.emit(UserLoggedOut(timestamp: Date()), mode: .main)
/// ```
public final class ServiceEventBus {
    /// Global shared bus.
    public static let shared = ServiceEventBus()

    private typealias HandlerEntry = (id: UUID, mode: SubscriberThreadMode, handler: (Any) -> Void)

    private struct State {
        var handlers: [ObjectIdentifier: [HandlerEntry]] = [:]
        var stickyEvents: [ObjectIdentifier: Any] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Subscribe to events of a specific type. Returns a token — retain it
    /// to keep the subscription alive. Auto-removed on deinit.
    ///
    /// - Parameter mode: Thread preference for this handler. `.posting` follows
    ///   the emitter's dispatch mode; `.main` / `.background` always override.
    /// - Parameter receiveSticky: If `true`, immediately delivers the last
    ///   sticky event of this type (if any) to the handler.
    public func on<T>(_ type: T.Type, mode: SubscriberThreadMode = .posting, receiveSticky: Bool = false, _ handler: @escaping (T) -> Void) -> KFEventToken {
        let id = UUID()
        let key = ObjectIdentifier(T.self)
        let wrapped: (Any) -> Void = { value in
            if let event = value as? T { handler(event) }
        }

        let stickySnapshot: T? = state.withLock { s -> T? in
            s.handlers[key, default: []].append((id, mode, wrapped))
            return receiveSticky ? (s.stickyEvents[key] as? T) : nil
        }

        // Deliver sticky event (if any) outside the lock
        if let sticky = stickySnapshot {
            dispatch((id: id, mode: mode, handler: wrapped), event: sticky)
        }

        return KFEventToken { [weak self, id] in
            guard let self else { return }
            self.state.withLock { s in
                s.handlers[key]?.removeAll { $0.id == id }
                if s.handlers[key]?.isEmpty == true {
                    s.handlers.removeValue(forKey: key)
                }
            }
        }
    }

    /// Emit an event to all current subscribers of its type.
    /// - Parameter event: The event value.
    /// - Parameter mode: How handlers are dispatched.
    /// - Parameter sticky: If `true`, the event is stored and replayed to
    ///   future subscribers that call `on()` with `receiveSticky: true`.
    public func emit<T>(_ event: T, mode: EventDispatchMode = .posting, sticky: Bool = false) {
        let key = ObjectIdentifier(T.self)
        let snapshot = state.withLock { s -> [HandlerEntry] in
            if sticky { s.stickyEvents[key] = event as Any }
            return s.handlers[key] ?? []
        }

        switch mode {
        case .posting:
            for entry in snapshot {
                dispatch(entry, event: event)
            }
        case .main:
            let entries = snapshot
            DispatchQueue.main.async {
                for entry in entries {
                    self.dispatch(entry, event: event)
                }
            }
        case .background:
            let entries = snapshot
            DispatchQueue.global(qos: .default).async {
                for entry in entries {
                    self.dispatch(entry, event: event)
                }
            }
        }
    }

    /// Remove the sticky event for the given type (without affecting subscribers).
    public func removeSticky<T>(_ type: T.Type) {
        state.withLock { $0.stickyEvents.removeValue(forKey: ObjectIdentifier(T.self)) }
    }

    /// Remove all subscriptions and sticky events.
    public func reset() {
        state.withLock { s in
            s.handlers.removeAll()
            s.stickyEvents.removeAll()
        }
    }

    // MARK: - Private

    /// Apply subscriber-level thread mode on top of emitter-level dispatch.
    private func dispatch<T>(_ entry: HandlerEntry, event: T) {
        switch entry.mode {
        case .posting:
            entry.handler(event)
        case .main:
            DispatchQueue.main.async { entry.handler(event) }
        case .background:
            DispatchQueue.global(qos: .default).async { entry.handler(event) }
        }
    }
}
