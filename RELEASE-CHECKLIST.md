# Release checklist

This is a release candidate, not authorization to publish.

## Owner decisions required
- MIT license selected for code and documentation. Greate logo and trademark rights are reserved; see BRANDING.md.
- Confirm redistribution terms for the generated app icon and the permitted use of the Greate logo by forks; replace or omit assets if necessary.
- Decide the public project name, repository, support/security contact, and distribution method. Do not invent contact information.

## Before publication
- Independently review source, generated assets, contributors, dependencies and all files to be published for secrets, personal information and licensing.
- Verify macmon install/version, missing executable, corrupt output, timeout and permission behavior on supported hardware. Do not assume undocumented interfaces will work across macOS versions.
- Test graphical layout, launch, quit, notification permission/delivery, sleep/wake, long-running collection, retention and upgrades on clean Macs. Seven-day continuous operation is not yet verified.
- Developer ID signing and notarization are required for a conventional trusted direct-download distribution; current local build is ad-hoc only. Verify Gatekeeper behavior and the final signing identity before distribution.
- Ensure no user history, local paths, build artifacts, credentials or private files are published. Do not publish the parent audit directory.

## Security review (2026-10-28)
- Scope: source, build script, plist, tests and included assets in this directory; no penetration test or independent security audit was performed.
- App records local hardware telemetry and has no telemetry transmission. The Greate logo opens the company website in the browser when clicked. No privileged helper, login item or fan-control code found in the reviewed source. Runtime behavior and dependency behavior are not formally proven.
- External dependency: hard-coded Homebrew executable at `/opt/homebrew/bin/macmon`; an attacker who can replace it can execute code as the user. Installation provenance and executable integrity are not verified by this app. Missing/error readings are shown as unavailable.
- macmon's hardware interfaces are undocumented and readings or support may change. Values are estimates/averages, not proof that hardware is safe; avoid diagnosing fan health from a single reading.
- History is kept as local JSONL without encryption and must not be committed. Its parent directory inherits the user's permissions; it contains timestamps and system telemetry.
- Build script disables the SwiftPM build sandbox and produces an ad-hoc signed binary. Only build trusted sources; this output is not notarized for public distribution.
- The repo assets were copied without extended attributes from local files. Ownership and redistribution rights are not independently verified.
