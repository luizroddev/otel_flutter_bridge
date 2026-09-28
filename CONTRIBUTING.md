# Contributing

Thanks for helping. This library is meant to stay small and easy to review.

## Setup

```bash
flutter pub get          # resolves the whole pub workspace
make up                  # local Jaeger (Docker)
make test swift-test     # everything CI runs, except the iOS build
```

## Proposing a change

1. Open an issue first for anything beyond a small fix, especially changes to
   redaction, the native bridge format or failure behaviour. Those need a
   spec update (`docs/specs`) and often an ADR (`docs/adr`).
2. Keep commits small, each with its tests.
3. Redaction changes need tests in `test/redaction_test.dart` for both what
   must be removed and what must be kept.
4. Run `make test swift-test` (and `make it` when touching export) before
   opening the pull request. Nothing merges with CI red.
5. Add an entry under "Unreleased" in `CHANGELOG.md`.

## Principles to keep

- Never break the app: no public method throws.
- Zero swizzling and zero hooks.
- Privacy by default: new attributes are not allowed until a spec says so.
- The standard OpenTelemetry API, not a custom one.
- Nothing specific to any company in the code.

## Versions

Semantic versioning. `0.x` while unstable. Every release has a changelog
entry and lists its dependencies.
