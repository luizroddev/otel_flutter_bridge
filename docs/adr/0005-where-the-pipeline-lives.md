# 0005. Where the pipeline lives

Status: proposed. To be decided at M1 with numbers from the spike on a
physical device, in Release.

## Context
Native spans can either be sent to Dart over the platform channel (one
pipeline, in Dart) or exported natively (pipeline in Swift, Dart spans sent
to native instead).

## Current implementation (proposal)
Pipeline in Dart. Native spans cross the channel in batches of up to 64 and
are merged as OTLP protobuf into the same request path. This also covers the
risk "the Dart SDK does not accept spans created outside it": native spans
never become SDK spans; they go straight to OTLP.

## To measure at M1
- Channel cost per batch (64 spans) on the lowest supported device.
- Startup time impact of `initialize` and native `start`.
- Frames over budget while exporting.

## Alternative
Pipeline in native code. Choose it if the
channel cost is too high; redaction would then need a Swift port with the
same test battery.

## Consequences
Record the numbers here and change the status to accepted or superseded.
