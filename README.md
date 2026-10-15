# WalkingPad → Apple Health Bridge

A small SwiftUI iOS app that connects to a SportsTech / KingSmith / WalkingPad
treadmill over Bluetooth Low Energy, reads live step data, and writes it into
Apple Health. It also keeps its own local session history and charts.

## What it does

- Scans for BLE treadmills and auto-detects the protocol family.
- Parses **FTMS** (`1826`, characteristic `2ACD`) using the FitShow-module
  layout observed on SportsTech pads:
  - instantaneous speed = bytes 2–3 ÷ 100 (km/h),
  - distance = bytes 4–6 (metres),
  - step count = final little-endian `uint16` of the vendor trailer.
- Also parses the **Classic WalkingPad** (`FE00` / notify `FE01` / write `FE02`)
  18-byte status frames with polling.
- Recognises **FitShow** (`FFF0`) and **KingSmith `0x1234`** services (logged,
  telemetry parsing not yet implemented).
- Writes **incremental** step-count samples to Apple Health with duplicate
  detection and a daily running total.
- Configurable Health send interval (1–60 s) and a pause/resume toggle.
- Local session detection with totals (7 days / 30 days / all time), a
  per-session bar chart, and a deletable session list.
- Copyable in-app BLE debug log (raw notifications as hex, discovery, errors).

## What it does NOT do

- It is **read-only**: it never starts, stops, or changes the belt speed.
- It writes **step count only** to Apple Health (no workout records, active
  energy, or speed samples).

## Requirements

- iPhone or iPad running iOS 17+
- Xcode 15+ with an Apple ID (free Personal Team works)
- A SportsTech / KingSmith / WalkingPad treadmill that speaks one of the
  supported BLE protocols

## Build from clone

1. Open `WalkingPadHealthBridge.xcodeproj` in Xcode.
2. Select the `WalkingPadHealthBridge` target → **Signing & Capabilities**.
3. Choose **your own Team** (the committed project intentionally ships with no
   team and a placeholder bundle id, `com.example.WalkingPadHealthBridge`).
4. Ensure **HealthKit** capability is present (already configured).
5. Connect your iPhone, select it as the run destination, and press **⌘R**.

> A free Apple ID installs the app but it expires after 7 days and must be
> re-installed from Xcode. A paid Developer account avoids that.

### Info.plist keys

Already included in `WalkingPadHealthBridge/Info.plist`:

| Key | Value |
|---|---|
| `NSBluetoothAlwaysUsageDescription` | Bluetooth access to read the walking pad |
| `NSHealthShareUsageDescription` | This app reads nothing from Apple Health |
| `NSHealthUpdateUsageDescription` | This app writes step counts into Apple Health |

## First run

1. Launch the app on your iPhone and grant the HealthKit permission.
2. Tap **Scan / Connect** and start walking on the pad.
3. The app auto-connects, detects the protocol, and streams live readings.
4. Steps are written to Apple Health at most once per send interval, only when
   the cumulative count increases.

## Command-line build

```sh
xcodebuild -project WalkingPadHealthBridge.xcodeproj \
  -scheme WalkingPadHealthBridge \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Troubleshooting

- **App does not see the pad**: make sure no other device (including the
  official app) is connected. Only one BLE central can hold the link.
- **Connects but steps never increase**: open the BLE debug log (antenna icon).
  If you see `parseFTMS ... steps=`, the parser decoded a value. If the step
  field is elsewhere on your model, capture the raw hex lines and open an issue.
- **Steps not in Apple Health**: check Settings → Privacy & Security → Health →
  WalkingPadHealthBridge and confirm Step Count is enabled.

## Reverse-engineering references

- [Belt Control — WalkingPad / KingSmith Bluetooth protocols](https://beltcontrol.com/walkingpad-bluetooth-protocol)
- [FitShow FS-BT-C1 FTMS notes](https://github.com/aradix85/fitshow-treadmill-accessible/blob/main/docs/PROTOCOL.md)
- [Mwea/walkingpad-js protocol spec](https://github.com/Mwea/walkingpad-js/blob/main/docs/protocol_spec.md)

## License

MIT — see [LICENSE](LICENSE).
