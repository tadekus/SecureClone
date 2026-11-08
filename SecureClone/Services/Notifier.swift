//
//  Notifier.swift
//  SecureClone
//
//  macOS notifications when a job finishes or fails. Best effort: an app
//  that is not properly signed may be refused by the notification center,
//  and that is fine — the log and summary remain the source of truth.
//

import Foundation
import UserNotifications
import AppKit

enum Notifier {
    private static var asked = false

    static func requestPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, sound: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if sound { c.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
        if sound { NSSound(named: "Glass")?.play() }
    }
}
