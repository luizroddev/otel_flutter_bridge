import Foundation
import UIKit

/// Sends what is pending when the app goes to the background, and records
/// it in the journey. Started by `OtelFlutterBridge.start`.
///
/// - Background: a `device.app.lifecycle` event (OpenTelemetry event
///   conventions) with `ios.app.state` = `background`, then a background
///   task while native spans and events go to Dart and Dart sends
///   everything (`flush` on the channel). The task ends when Dart replies,
///   or after `flushTimeout`.
/// - Foreground and terminate: the same event with `foreground` /
///   `terminate`; on terminate, a last best-effort flush.
///
/// `active` and `inactive` are not recorded: they also happen for a system
/// dialog or the notification center, and would double the events.
final class AppLifecycle: NSObject {
  static let shared = AppLifecycle()

  /// How long the background task waits for Dart.
  var flushTimeout: TimeInterval = 10

  private var started = false

  func start() {
    guard !started else { return }
    started = true
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
    center.addObserver(self, selector: #selector(willTerminate),
                       name: UIApplication.willTerminateNotification, object: nil)
  }

  @objc private func didEnterBackground() {
    record("background")
    let app = UIApplication.shared
    let task = BackgroundTask()
    task.id = app.beginBackgroundTask(withName: "otel_flutter_bridge.flush") { task.end(app) }
    OtelFlutterBridge.shared.flush()
    OtelFlutterBridge.shared.flushDart { DispatchQueue.main.async { task.end(app) } }
    DispatchQueue.main.asyncAfter(deadline: .now() + flushTimeout) { task.end(app) }
  }

  @objc private func willEnterForeground() {
    record("foreground")
  }

  @objc private func willTerminate() {
    record("terminate")
    OtelFlutterBridge.shared.flush()
    OtelFlutterBridge.shared.flushDart {}
  }

  private func record(_ state: String) {
    Journey.record(JourneyKeys.appLifecycle, [JourneyKeys.iosAppState: .string(state)])
  }
}

/// A background task ended exactly once: when Dart replies, on timeout or
/// when iOS says time is up, whichever comes first.
private final class BackgroundTask {
  var id = UIBackgroundTaskIdentifier.invalid
  private let ended = OnceFlag()

  func end(_ app: UIApplication) {
    guard id != .invalid, ended.claim() else { return }
    app.endBackgroundTask(id)
  }
}
