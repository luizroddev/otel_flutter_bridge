import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// A low-cardinality `error.type` for [error].
///
/// Common types get a fixed name, because `runtimeType` is obfuscated in
/// release builds built with `--obfuscate`. Other types fall back to
/// `runtimeType`.
String errorTypeOf(Object error) => switch (error) {
      http.ClientException() => 'ClientException',
      PlatformException() => 'PlatformException',
      MissingPluginException() => 'MissingPluginException',
      TimeoutException() => 'TimeoutException',
      _ => error.runtimeType.toString(),
    };

/// Marks [span] as failed with `error.type` only. The error text is never
/// recorded: it is free text and may carry personal data.
void markSpanError(Span span, Object error, {String? type}) {
  try {
    final t = type ?? errorTypeOf(error);
    span
      ..setStringAttribute('error.type', t)
      ..setStatus(SpanStatusCode.Error, t);
  } catch (_) {
    // Telemetry never breaks the app.
  }
}

/// Global sanitizer for exceptions the SDK records itself (`withSpanAsync`,
/// `startActiveSpanAsync`): keeps the type, drops the message and the stack
/// trace.
SanitizedSpanException sanitizeSpanException(Object error, StackTrace _) {
  final type = errorTypeOf(error);
  return SanitizedSpanException(
    type: type,
    message: type,
    statusDescription: type,
  );
}
