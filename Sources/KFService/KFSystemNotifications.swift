// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

extension Notification.Name {
    /// UIKit system notifications mapped without importing UIKit.
    enum KFSystem {
        static let didEnterBackground = Notification.Name("UIApplicationDidEnterBackgroundNotification")
        static let willEnterForeground = Notification.Name("UIApplicationWillEnterForegroundNotification")
        static let didReceiveMemoryWarning = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")
        static let willTerminate = Notification.Name("UIApplicationWillTerminateNotification")
    }
}
