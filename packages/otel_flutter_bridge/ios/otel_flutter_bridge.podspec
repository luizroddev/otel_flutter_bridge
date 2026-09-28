Pod::Spec.new do |s|
  s.name             = 'otel_flutter_bridge'
  s.version          = '0.1.0'
  s.summary          = 'OpenTelemetry bridge between native iOS code and Flutter.'
  s.description      = 'Sends native OpenTelemetry spans to the Dart pipeline and continues Dart traces in native code.'
  s.homepage         = 'https://github.com/luizroddev/otel_flutter_bridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'otel_flutter_bridge authors' => 'https://github.com/luizroddev/otel_flutter_bridge' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  # Pinned exactly, so each release documents the reviewed versions. See docs/adr/0004.
  s.dependency 'OpenTelemetry-Swift-Api', '2.5.1'
  s.dependency 'OpenTelemetry-Swift-Sdk', '2.5.1'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'
  s.resource_bundles = { 'otel_flutter_bridge_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }
end
