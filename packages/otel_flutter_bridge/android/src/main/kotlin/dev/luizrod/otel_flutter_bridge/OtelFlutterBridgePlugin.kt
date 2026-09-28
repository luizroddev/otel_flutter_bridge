package dev.luizrod.otel_flutter_bridge

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android end of the bridge channel.
 *
 * The native Android bridge (sending OpenTelemetry Java spans to Dart) is
 * planned for milestone M7. Until then this plugin only acknowledges the
 * channel so Dart telemetry works normally on Android.
 */
class OtelFlutterBridgePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "otel_flutter_bridge")
    channel.setMethodCallHandler(this)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "ready", "setEnabled" -> result.success(null)
      else -> result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }
}
