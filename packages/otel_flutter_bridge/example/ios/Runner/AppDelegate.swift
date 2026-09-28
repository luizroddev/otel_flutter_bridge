import Flutter
import OpenTelemetryApi
import otel_flutter_bridge
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 1. Start the native side first, before Flutter runs.
    OtelFlutterBridge.shared.start(resourceAttributes: [
      "os.name": .string("iOS"),
      "os.version": .string(UIDevice.current.systemVersion),
    ])

    // 2. A span created before Dart is ready. It waits in the queue and
    //    reaches the backend in the same session as the Dart spans.
    let launch = OtelFlutterBridge.shared.tracer()
      .spanBuilder(spanName: "app.launch.native").startSpan()
    launch.setAttribute(key: "app.launch.cold", value: true)
    launch.end()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PocNativeChannel") else { return }
    PocNativeChannel.register(messenger: registrar.messenger())
  }
}

/// Stands in for the host app's existing native code, called from Flutter.
/// Shows how a real native feature continues the Dart trace.
enum PocNativeChannel {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "poc/native", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "loadCart": loadCart(call.arguments, result: result)
      case "nativeFailure": nativeFailure(call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Native work plus a native HTTP call, both children of the Dart span.
  private static func loadCart(_ arguments: Any?, result: @escaping FlutterResult) {
    let span = OtelFlutterBridge.shared.startSpan("NativeCart.load", arguments: arguments)
    span.setAttribute(key: "app.native.feature", value: "cart")

    // Simulated local work, as its own child span.
    let work = OtelFlutterBridge.shared.tracer().spanBuilder(spanName: "NativeCart.readCache")
      .setParent(span).startSpan()
    Thread.sleep(forTimeInterval: 0.03)
    work.end()

    let args = arguments as? [String: Any]
    guard let urlString = args?["url"] as? String, let url = URL(string: urlString) else {
      span.end()
      result("sem URL: só processamento nativo")
      return
    }
    TracedURLSession.dataTask(with: URLRequest(url: url), parent: span.context) { _, response, error in
      span.end()
      DispatchQueue.main.async {
        if let error {
          result("HTTP nativo falhou: \(type(of: error))")
        } else {
          result("HTTP nativo \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
      }
    }
  }

  private static func nativeFailure(_ arguments: Any?, result: @escaping FlutterResult) {
    let span = OtelFlutterBridge.shared.startSpan("NativePayment.confirm", arguments: arguments)
    span.status = .error(description: "payment refused for customer 123.456.789-09")
    span.addEvent(name: "exception", attributes: [
      "exception.type": .string("PaymentError"),
      "exception.message": .string("card 4111 1111 1111 1111 declined"),
    ])
    span.end()
    result(FlutterError(code: "payment_failed", message: "Pagamento recusado (simulado)", details: nil))
  }
}
