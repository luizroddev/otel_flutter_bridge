# Common tasks. Run `make help`.
.PHONY: help up down backend test swift-test it analyze example-ios all

help:
	@echo "make up          Start Jaeger (UI http://localhost:16686, OTLP :4318)"
	@echo "make backend     Run the demo backend on :8080 (continues the app's trace)"
	@echo "make test        Dart analysis + unit tests of both packages"
	@echo "make swift-test  Swift unit tests of the iOS core (macOS)"
	@echo "make it          Integration test against the local Jaeger (needs make up)"
	@echo "make example-ios Run the example app on an iOS simulator"
	@echo "make down        Stop Jaeger"

up:
	docker compose up -d

down:
	docker compose down

backend:
	dart run tools/demo_backend/bin/server.dart

analyze:
	dart format --output=none --set-exit-if-changed packages tools
	flutter analyze

test: analyze
	cd packages/otel_flutter_bridge && flutter test
	cd packages/otel_flutter_bridge_dio && flutter test

swift-test:
	cd native_tests/ios && swift test

it:
	cd packages/otel_flutter_bridge && OTEL_JAEGER_TEST=1 flutter test test/integration/jaeger_test.dart

example-ios:
	cd packages/otel_flutter_bridge/example && flutter run

all: test swift-test
