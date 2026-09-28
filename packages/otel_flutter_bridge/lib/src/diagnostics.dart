/// Kinds of internal problems the bridge reports.
enum BridgeDiagnosticKind {
  /// Initialization failed; the bridge stays disabled.
  initFailed,

  /// A queue was full and the oldest item was dropped.
  queueFull,

  /// The transport did not accept a request.
  exportFailed,

  /// A native batch, or some spans in it, were malformed.
  nativeBatchRejected,

  /// Something unexpected happened inside the bridge. Data was dropped.
  internalError,
}

/// An internal problem. Never carries span data or personal data.
class BridgeDiagnostic {
  /// Creates a diagnostic.
  const BridgeDiagnostic(this.kind, [this.detail]);

  /// What happened.
  final BridgeDiagnosticKind kind;

  /// A short technical detail, such as an error type or a count.
  final String? detail;

  @override
  String toString() => detail == null
      ? 'BridgeDiagnostic(${kind.name})'
      : 'BridgeDiagnostic(${kind.name}: $detail)';
}

/// Receives diagnostics. Extension point: forward them to the app's logger.
typedef DiagnosticListener = void Function(BridgeDiagnostic diagnostic);
