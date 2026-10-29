import Flutter
import OpenTelemetryApi
import otel_flutter_bridge
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Host mode (POC_HOST=1, see poc_config.dart).
  static let hostMode = ProcessInfo.processInfo.environment["POC_HOST"] == "1"
  private var hostChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 1. Start the native side first, before Flutter runs.
    OtelFlutterBridge.shared.start(resourceAttributes: [
      "os.name": .string("iOS"),
      "os.version": .string(UIDevice.current.systemVersion),
    ])
    if AppDelegate.hostMode { startHostMode() }

    // 2. A span created before Dart is ready. It waits in the queue and
    //    reaches the backend in the same session as the Dart spans.
    let launch = OtelFlutterBridge.shared.tracer()
      .spanBuilder(spanName: "app.launch.native").startSpan()
    launch.setAttribute(key: "app.launch.cold", value: true)
    launch.end()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Host mode: this app owns the session, and its own HTTP client sends
  /// the telemetry Dart batches.
  private func startHostMode() {
    OtelFlutterBridge.shared.setSession(id: UUID().uuidString.lowercased())
    OtelFlutterBridge.shared.exportHandler = { export, completion in
      guard let request = export.urlRequest() else { return completion(false) }
      // The app's client is traced; the request is marked as telemetry, so
      // it never becomes a span itself.
      TracedURLSession.dataTask(with: request) { _, response, error in
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        NSLog("[poc] %@ sent by the app's client: HTTP %d", export.signal, status)
        completion(error == nil && (200..<300).contains(status))
      }
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PocNativeChannel") else { return }
    PocNativeChannel.register(messenger: registrar.messenger())
    // Dart cannot read the environment on iOS: it asks here.
    let host = FlutterMethodChannel(name: "poc/host", binaryMessenger: registrar.messenger())
    host.setMethodCallHandler { _, result in result(AppDelegate.hostMode) }
    hostChannel = host
  }
}

/// Stands in for the host app's existing native code, called from Flutter.
/// Shows how a real native feature continues the Dart trace with one line
/// per channel (`traced`), and calls Flutter back in the same trace.
enum PocNativeChannel {
  private static var channel: FlutterMethodChannel?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "poc/native", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler(OtelFlutterBridge.shared.traced(channel: "poc/native") { call, result in
      switch call.method {
      case "loadCart": loadCart(call.arguments, result: result)
      case "nativeFailure": nativeFailure(result: result)
      case "notifyFlutter": notifyFlutter(result: result)
      case "nativeAddress": nativeAddress(result: result)
      default: result(FlutterMethodNotImplemented)
      }
    })
  }

  /// Native work plus a native HTTP call, both children of the channel span.
  private static func loadCart(_ arguments: Any?, result: @escaping FlutterResult) {
    // Simulated local work, as its own child span (parent: the current span).
    let work = OtelFlutterBridge.shared.span("NativeCart.readCache",
                                             attributes: ["app.native.feature": .string("cart")])
    Thread.sleep(forTimeInterval: 0.03)
    work.end()

    let args = arguments as? [String: Any]
    guard let urlString = args?["url"] as? String, let url = URL(string: urlString) else {
      result("sem URL: só processamento nativo")
      return
    }
    // No parent argument: the traced handler's span is current.
    TracedURLSession.dataTask(with: URLRequest(url: url)) { _, response, error in
      DispatchQueue.main.async {
        if let error {
          result("HTTP nativo falhou: \(type(of: error))")
        } else {
          result("HTTP nativo \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
      }
    }
  }

  private static func nativeFailure(result: @escaping FlutterResult) {
    TraceContext.current?.addEvent(name: "exception", attributes: [
      "exception.type": .string("PaymentError"),
      "exception.message": .string("card 4111 1111 1111 1111 declined for 123.456.789-09"),
    ])
    result(FlutterError(code: "payment_failed", message: "Pagamento recusado (simulado)", details: nil))
  }

  /// A native screen inside a flow Flutter started: the screen and the
  /// action are recorded here, with the same flow run, and the run ends
  /// here. Flutter sees it ended (`checkout.isEnded`).
  private static func nativeAddress(result: @escaping FlutterResult) {
    Journey.screen(ShopScreen.address)
    let confirm = Journey.begin(ShopAction.confirmAddress)
    Thread.sleep(forTimeInterval: 0.05) // the user confirms
    confirm.end(.success)
    Journey.flowRun(ShopFlow.checkout)?.end(.success)
    result("endereço confirmado na tela nativa")
  }

  /// A stored callback (like a manager's queue) that later calls Flutter:
  /// `bind` keeps it in this trace, `invokeTraced` carries it to Dart.
  private static func notifyFlutter(result: @escaping FlutterResult) {
    let later = OtelFlutterBridge.shared.bind {
      channel?.invokeTraced("nativeEvent", arguments: ["kind": "cart"])
      result("evento enviado ao Flutter")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: later)
  }
}

// The fictional shop's native screens and actions. Codes are the raw
// values and must match the Dart enums where both sides use them
// (`checkout`).
enum ShopScreen: String, JourneyScreen {
  case address

  var label: String? { "Endereço (nativa)" }
}

enum ShopFlow: String, JourneyFlow {
  case checkout
}

enum ShopAction: String, JourneyAction {
  case confirmAddress

  var label: String? { "Confirmou o endereço" }
}
