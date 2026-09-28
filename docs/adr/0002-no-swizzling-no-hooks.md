# 0002. Zero swizzling and zero hooks

Status: accepted

## Context
Runtime app protection tools and security reviews flag or block
method swizzling, `URLProtocol` registration, and global hooks. They also
change system behaviour in ways that are hard to prove safe.

## Decision
The library only instruments what the app calls explicitly: spans it
creates, requests sent through `OtelDioInterceptor` or `TracedURLSession`,
channel calls made with `invokeTraced`. No swizzling, no `URLProtocol`, no
`HttpOverrides.global`, no zone or `FlutterError.onError` takeover.

## Alternatives discarded
- OTel Swift `URLSessionInstrumentation` (swizzles).
- Global `HttpOverrides` in Dart.

## Consequences
Coverage is opt-in: uninstrumented calls do not appear. That is the price of
predictability and of passing protected builds; the example app shows the
minimal calls to add.
