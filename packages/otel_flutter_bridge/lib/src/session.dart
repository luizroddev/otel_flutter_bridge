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

  /// The current session id. Starts a new session when there is none, when
  /// the last activity is older than the inactivity timeout, or when the
  /// session reached its maximum duration. Each call counts as activity.
  @override
  String get currentId {
    final now = _clock();
    if (_id == null || _isExpired(now)) _start(now);
    _lastActivity = now;
    return _id!;
  }

  /// Ends the current session. The next [currentId] starts a new one.
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

/// Generates a 128-bit random id as 32 lowercase hex characters.
String newSessionId(Random random) {
  final sb = StringBuffer();
  for (var i = 0; i < 16; i++) {
    sb.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
