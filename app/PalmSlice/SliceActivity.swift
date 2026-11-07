import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps a slice running when the user leaves the app. Every slice gets the
/// short grace period of a UIKit background task; on iOS 26 a slice still
/// running after a few seconds also becomes a continued-processing task, which
/// keeps running in the background and shows its progress in the system UI
/// (where the user can also stop it). A slice that ends while the app is in
/// the background posts a notification with the result.
@MainActor
final class SliceActivity {
    static let shared = SliceActivity()

    /// Listed in Info.plist's BGTaskSchedulerPermittedIdentifiers.
    private static let identifierPattern = "com.adickin.PalmSlice.slice.*"
    /// Slices shorter than this don't show the system's progress UI.
    private static let longSliceDelay: Duration = .seconds(4)

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var longSliceTimer: Task<Void, Never>?
    private var continuedTask: BGTask?
    private var registered = false
    private var phase = "Slicing"
    private var progress = 0.0
    private var onExpire: (() -> Void)?

    /// Starts covering a slice; `onExpire` cancels it if the system or the user stops the task.
    func begin(onExpire: @escaping () -> Void) {
        end(success: false)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        self.onExpire = onExpire
        phase = "Slicing"
        progress = 0
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Slice") { [weak self] in
            // Out of grace time: the app suspends and the slice resumes when it comes back.
            self?.endBackgroundTask()
        }
        longSliceTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.longSliceDelay)
            guard !Task.isCancelled else { return }
            if #available(iOS 26, *) { self?.submitContinuedTask() }
            self?.askForNotifications()
        }
    }

    func update(phase: String, progress: Double) {
        self.phase = phase
        self.progress = progress
        if #available(iOS 26, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64((progress * 100).rounded())
            task.updateTitle("Slicing", subtitle: phase)
        }
    }

    /// Ends the slice's background time. `title`/`body` are posted as a
    /// notification if the app is in the background.
    func end(success: Bool, title: String? = nil, body: String = "") {
        longSliceTimer?.cancel()
        longSliceTimer = nil
        onExpire = nil
        let continued = continuedTask
        let background = backgroundTask
        continuedTask = nil
        backgroundTask = .invalid
        // Both keep the app running, so they end once the notification is handed over.
        let finish = {
            if #available(iOS 26, *), let task = continued as? BGContinuedProcessingTask {
                task.progress.completedUnitCount = task.progress.totalUnitCount
                task.setTaskCompleted(success: success)
            }
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        guard let title, UIApplication.shared.applicationState != .active else { return finish() }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in
            Task { @MainActor in finish() }
        }
    }

    private static let notificationID = "slice-finished"

    /// Asks once, while a long slice runs in the foreground (the prompt can't
    /// show in the background), so people who never wait on a slice aren't asked.
    private func askForNotifications() {
        guard UIApplication.shared.applicationState == .active else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    @available(iOS 26, *)
    private func submitContinuedTask() {
        // Requests can only come from the app in the foreground.
        guard UIApplication.shared.applicationState == .active else { return }
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifierPattern, using: .main) { task in
                MainActor.assumeIsolated { SliceActivity.shared.started(task) }
            }
            guard registered else { return }
        }
        let identifier = Self.identifierPattern.dropLast() + UUID().uuidString
        let request = BGContinuedProcessingTaskRequest(identifier: String(identifier), title: "Slicing", subtitle: phase)
        request.strategy = .fail   // a slice that has already started can't wait in a queue
        try? BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26, *)
    private func started(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        // The slice may have finished between submitting and starting.
        guard onExpire != nil else { return task.setTaskCompleted(success: true) }
        task.progress.totalUnitCount = 100
        task.expirationHandler = {
            // Cancels the slice; ending it completes the task.
            Task { @MainActor in SliceActivity.shared.onExpire?() }
        }
        continuedTask = task
        update(phase: phase, progress: progress)
    }
}
