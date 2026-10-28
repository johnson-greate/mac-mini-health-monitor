# Mac Mini Health Monitor

A local, read-only macOS menu-bar app for Apple Silicon, developed by Greate (HK) Limited. It runs only while open. It does not install a login item, background service, helper, or updater; it does not control fans or transmit telemetry. The Greate logo opens the company website in your browser when clicked. This is a release candidate, not yet an independently audited product.

## Build and run

Requires Apple Command Line Tools with Swift and the macOS SDK. Temperature and fan readings require the separately installed [macmon](https://github.com/vladkens/macmon) at `/opt/homebrew/bin/macmon` (tested with 0.10.0). Install it separately using `brew install macmon`; it is not bundled with this project. Disk and thermal state continue to work without it. Tested on a Mac mini M4 running macOS 26.5.1; other models and OS versions are unverified. From this directory:

```sh
sh build-app.sh
open "build/Mac Mini Health Monitor.app"
```

The script creates an ad-hoc-signed app with bundle identifier `hk.greate.MacMiniHealthMonitor`. It does not install or launch it. Click the menu-bar icon to inspect readings and quit. The app is not Developer ID signed or notarized; Gatekeeper may block distribution to other Macs. The script disables Swift Package Manager's build sandbox; run it only on trusted source. The app itself does not need administrator access.

## Readings and history

The app samples approximately once a minute while running. Root available space is `statfs` `f_bavail * f_bsize`, displayed in GiB (1 GiB = 1,073,741,824 bytes); compare with `df -k /` by dividing its available KiB by 1,048,576. Thermal state comes from `ProcessInfo.thermalState` and is not a temperature. CPU and GPU average temperatures and first fan RPM are read with `/opt/homebrew/bin/macmon pipe --samples 1 --interval 1000`, without sudo; SSD temperature remains N/A. macmon uses undocumented system interfaces which may stop working after macOS updates. Missing, invalid or failed sensor readings are N/A; failures are visible in the menu. Older saved records remain compatible and show N/A for sensors.

History is stored at `~/Library/Application Support/MacMiniHealthMonitor/history.jsonl`, separate from audit and personal files. Startup and hourly pruning keep the preceding seven days, with an additional 10,100-sample cap to bound storage after unusual clock changes or sampling frequency. Records in the future relative to the clock are discarded during pruning. Disk read failures are recorded as N/A; storage failures are shown in the menu and are not presented as saved readings. A corrupt file is left intact and blocks further writes; close the app and inspect or move it yourself before restarting if recovery is needed.

The history shows every retained reading, minimum available space, highest known thermal state, and missing periods. A gap is a period over 120 seconds between readings, or between the seven-day window edge/latest reading and the nearest sample. The app cannot distinguish sleep, shutdown and being closed, and does not interpolate readings. A last saved reading over 120 seconds old is marked stale. The first launch normally shows a leading gap because earlier history does not exist.

## Alerts

The default low-space threshold is 20 GiB, adjustable in the menu from 1 to 1,000 GiB. A warning is triggered when available space falls below the threshold, and when thermal state reaches serious or critical. Each condition must recover before another warning; unknown readings do not count as recovery. On restart the latest saved reading initializes the warning state. These are advisory operating thresholds, not hardware temperature limits.

Click **Enable** in the menu to request notification permission. If denied, monitoring and history continue; change permission in macOS System Settings. A crossing while notifications are disabled is not replayed later. Delivery also depends on macOS notification settings, Focus and the app's ad-hoc signature; building a new signature can affect permission or delivery on some systems.

## Tests

The installed Command Line Tools may not include XCTest. The standalone test executable uses no additional dependencies:

```sh
mkdir -p .build/tmp .build/module-cache
TMPDIR="$PWD/.build/tmp" CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift run --disable-sandbox --scratch-path "$PWD/.build" MonitorCoreTests
df -k /
```

It checks retention across restart, gap boundaries, warning recovery, corrupt and unwritable storage, and a root filesystem reading. GUI behavior, notification delivery, sleep/wake and seven days of continuous operation require separate manual verification.

## Privacy and safety

Measurements are stored only in the local history file described above; the app has no telemetry code. Clicking the Greate logo opens an external website in the default browser; your browser then connects to that website. The separately installed macmon is launched as the current user with fixed arguments; keep that executable and your Homebrew installation trusted. Do not use the readings as a substitute for hardware diagnosis. Removing the app does not remove its history; delete that file manually only if you no longer need it.

## License and branding

Project code and documentation are available under the [MIT License](LICENSE). The Greate logo and application icon are excluded; see [BRANDING.md](BRANDING.md). macmon is a separate MIT-licensed project; see [its license](https://github.com/vladkens/macmon/blob/main/LICENSE). If redistributing macmon or its code, retain the applicable upstream copyright and permission notice.
