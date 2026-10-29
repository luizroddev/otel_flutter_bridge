import 'dart:math';

import 'config.dart';
import 'pipeline.dart';

/// Keeps the current `session.id`. See `docs/specs/session.md`.
///
/// The id is 128 random bits from a secure source, as 32 lowercase hex
/// characters. It is not derived from anything about the user or the device,
/// so it cannot identify either.
class SessionManager implements SessionIdProvider {
  /// Creates a manager. [clock] and [random] exist for tests.
  SessionManager(
    this._config, {
    DateTime Function()? clock,
    Random? random,
  })  : _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  final SessionConfig _config;
  final DateTime Function() _clock;
  final Random _random;

  String? _id;
  DateTime? _startedAt;
  DateTime? _lastActivity;

  /// Called right after a session starts, with its id and the id of the
  /// session it follows (null for the first one and after [reset]).
  /// `initialize` uses it to record the `session.start` event.
  void Function(String id, String? previousId)? onStart;

  /// The current session id. Starts a new session when there is none, when
  /// the last activity is older than the inactivity timeout, or when the
  /// session reached its maximum duration. Each call counts as activity.
  @override
  String get currentId {
    final now = _clock();
    String? previous;
    var started = false;
    if (_id == null || _isExpired(now)) {
      previous = _id;
      _start(now);
      started = true;
    }
    _lastActivity = now;
    final id = _id!;
    if (started) {
      try {
        onStart?.call(id, previous);
      } catch (_) {
        // Telemetry never breaks the app.
      }
    }
    return id;
  }

  /// Ends the current session. The next [currentId] starts a new one, with
  /// no previous session: after a logout the next session may be another
  /// person's.
  void reset() {
    _id = null;
    _startedAt = null;
    _lastActivity = null;
  }

  bool _isExpired(DateTime now) =>
      now.difference(_lastActivity!) >= _config.inactivityTimeout ||
      now.difference(_startedAt!) >= _config.maxDuration;

  void _start(DateTime now) {
    _id = newSessionId(_random);
    _startedAt = now;
  }
}

/// The session of the native app, when it owns the session
/// (`SessionConfig.fromHost`). The native side sends its id through the
/// bridge; until it does, [fallback] gives one. Starting a session (and its
/// `session.start` event) is the native side's job.
class HostSession implements SessionIdProvider {
  /// Creates a host session that uses [fallback] until the host sends one.
  HostSession(this.fallback);

  /// Used until the host sends a session id.
  final SessionIdProvider fallback;

  String? _id;

  /// The id the host sent, or null.
  String? get hostId => _id;

  /// Sets the host's current session id. Empty values are ignored.
  void set(String? id) {
    if (id != null && id.isNotEmpty) _id = id;
  }

  @override
  String get currentId => _id ?? fallback.currentId;
}

/// Generates a 128-bit random id as 32 lowercase hex characters.
String newSessionId(Random random) {
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    sb.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
