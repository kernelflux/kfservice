// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// Retain this token to keep a KFServiceManager event subscription alive.
/// When the token is deallocated, the handler is automatically removed —
/// no need to call a separate "unsubscribe" method.
///
/// ```
/// // Keep this alive
/// private var token: KFEventToken?
///
/// token = KFServiceManager.on(UserLoggedOut.self) { event in
///     // handle logout
/// }
///
/// // token = nil or deinit → auto-unsubscribed
/// ```
public final class KFEventToken {
    private let remove: () -> Void

    init(_ remove: @escaping () -> Void) {
        self.remove = remove
    }

    deinit {
        remove()
    }

    /// Discard the token immediately (equivalent to setting it to nil).
    public func cancel() {
        remove()
    }
}
