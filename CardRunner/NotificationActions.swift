//
//  NotificationActions.swift
//  CardRunner
//
//  Makes CardRunner's macOS banner notifications ACTIONABLE. A completion
//  banner offers "Reveal in Finder" + "Eject Card"; a failure banner offers
//  "Retry". Tapping an action routes through the SAME NotificationCenter names
//  the menu items already post (`.menuOpenDestination`, `.menuEjectCard`,
//  `.menuStartIngest`), so the behaviour is identical to using the menu.
//
//  Dependency-free: only Foundation / AppKit / UserNotifications.
//

import Foundation
import AppKit
import UserNotifications

// MARK: - Identifiers

enum NotificationCategory {
    /// A transfer finished successfully — offers Reveal + Eject.
    static let complete = "INGEST_COMPLETE"
    /// A transfer failed — offers Retry.
    static let failed   = "INGEST_FAILED"
}

enum NotificationAction {
    static let reveal = "REVEAL_ACTION"
    static let eject  = "EJECT_ACTION"
    static let retry  = "RETRY_ACTION"
}

/// userInfo key carrying the exact folder path to reveal for a completion banner.
let kNotificationDestPathKey = "destPath"

// MARK: - Pure action → Notification.Name mapping (unit-testable)

/// Maps a notification action identifier to the existing in-app Notification.Name
/// that performs the equivalent behaviour. Returns nil for identifiers with no
/// mapping (e.g. the default/dismiss action). Kept as a free function with no
/// UNNotification dependency so it can be unit-tested directly.
func notificationName(forActionIdentifier identifier: String) -> Notification.Name? {
    switch identifier {
    case NotificationAction.reveal: return .menuOpenDestination
    case NotificationAction.eject:  return .menuEjectCard
    case NotificationAction.retry:  return .menuStartIngest
    default:                        return nil
    }
}

// MARK: - Delegate

/// Handles taps on notification action buttons. Set as
/// `UNUserNotificationCenter.current().delegate` at launch.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationActionHandler()

    /// Registers the actionable categories. Safe to call more than once.
    func registerCategories() {
        let reveal = UNNotificationAction(
            identifier: NotificationAction.reveal,
            title: "Reveal in Finder",
            options: [.foreground]
        )
        let eject = UNNotificationAction(
            identifier: NotificationAction.eject,
            title: "Eject Card",
            options: []
        )
        let retry = UNNotificationAction(
            identifier: NotificationAction.retry,
            title: "Retry",
            options: [.foreground]
        )

        let completeCategory = UNNotificationCategory(
            identifier: NotificationCategory.complete,
            actions: [reveal, eject],
            intentIdentifiers: [],
            options: []
        )
        let failedCategory = UNNotificationCategory(
            identifier: NotificationCategory.failed,
            actions: [retry],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current()
            .setNotificationCategories([completeCategory, failedCategory])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionID = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Reveal: prefer the exact folder path baked into userInfo (points at the
        // precise folder clips landed in). Fall back to posting .menuOpenDestination,
        // which opens the last completed folder / default destination.
        if actionID == NotificationAction.reveal,
           let path = userInfo[kNotificationDestPathKey] as? String,
           !path.isEmpty {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                completionHandler()
            }
            return
        }

        if let name = notificationName(forActionIdentifier: actionID) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: name, object: nil)
                completionHandler()
            }
            return
        }

        completionHandler()
    }

    /// Still show banners while the app is frontmost (harmless; notifyIfBackgrounded
    /// already gates on background state, so this mainly affects any future callers).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
