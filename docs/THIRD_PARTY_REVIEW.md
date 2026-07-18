# Third-Party Adoption Security Review: HyperVibe

**Repo:** `/Users/greg/Dev/contrib/hypervibe` (github.com/machinarii/hypervibe)
**Commit reviewed:** `1e7746a` ("Update banner.png"), authored by Jinsoo An
**Reviewer:** Albert (static read only; no repo scripts executed)
**Date:** 2026-07-18
**What it is:** Experimental macOS menu-bar app mapping Apple TV Siri Remote buttons/gestures to keyboard/mouse actions. A fork of [Remotastic](https://github.com/lauschue/Remotastic). Requires Accessibility + Input Monitoring + Bluetooth permissions.

---

## Summary

HyperVibe contains **no network code of any kind** — no sockets, no HTTP, no networking framework is even imported, so there is no exfiltration path. Keystroke/HID handling is exactly what is advertised: Siri Remote input is consumed and mapped to synthetic key/mouse events, with no keystroke, clipboard, or text content written to any file. The only real notes are two hardened-runtime-weakening entitlements (one appears unnecessary), a world-readable `/tmp` diagnostic log containing benign remote-button metadata, and single-author brand-new-experimental maturity.

---

## Blockers (must-fix)

**None.** No network calls, no data exfiltration, no persistence of the app itself, no privilege escalation, no backdoors, no hardcoded credentials or hidden fetches in the build scripts.

---

## Notable Non-Blockers

1. **Hardened-runtime downgrade entitlements** (`HyperVibe.entitlements:7-10`). `com.apple.security.cs.disable-library-validation` is genuinely required to load Apple's unsigned private `MultitouchSupport.framework`. `com.apple.security.cs.allow-dyld-environment-variables` is **not obviously needed** — the framework is linked via `-F /System/Library/PrivateFrameworks` in `build.sh:51`, not via a `DYLD_*` env var. Together these weaken the process's hardened runtime (arbitrary unsigned dylibs + DYLD injection allowed). Low risk for a locally built, ad-hoc-signed binary you control, but the dyld-env entitlement could be dropped and re-tested.

2. **World-readable diagnostic log** (`RemoteDetector.swift:12-25`, `/tmp/hypervibe.log`). Written world-readable in `/tmp`. Content is benign: HID device metadata (vendor/product/usage), Siri Remote button events (`RemoteInputHandler.swift:94` logs page/usage/value + button name like `playPause`), and volume levels (`SystemVolume.swift`). **No injected keystrokes, no clipboard, no typed text, no general keyboard input is ever logged.** Any local user/process can read remote-button activity; minor privacy note, not a leak of sensitive input.

3. **Media-key event tap is system-wide but scope-limited** (`MediaKeyInterceptor.swift:24-40`). The `NX_SYSDEFINED` CGEvent tap sees media keys (play/pause/volume/mute/next/prev) from *all* sources, not just the remote. These are not keystrokes; the handler only reads keycode/state to map + consume, and logs nothing. General keyboard keystrokes are never tapped — the raw-HID callbacks (`RemoteInputHandler.handleInputValue`) are registered only on the *seized Siri Remote* devices, so the app has no visibility into normal typing. This is the correct reassurance for the Input Monitoring grant.

4. **`launchctl` subprocess** (`SiriRemoteApp.swift:169-223`, `RCDControl`). Spawns `/bin/launchctl` with fixed args (`bootout`/`bootstrap`/`print`) against `com.apple.rcd` only — suspends the daemon that auto-launches Music.app on Bluetooth AVRCP, restored on clean exit and at next login. No shell, no user-controlled arguments, no dynamic command construction. Session-scoped, reversible. **Not** persistence of HyperVibe (the app installs no launch agent or login item).

5. **Dead / unwired code** (quality, not security). `MediaController.swift` is never instantiated; `MenuBarManager.mediaController` is never assigned. `VolumeRevertGuard.prewarm()` (`SystemVolume.swift:79`) is never called, so its CoreAudio listener is never installed and the volume-revert guard is effectively inert. Functionality gaps only.

6. **Maturity / bus factor.** Single author (Jinsoo An, all 33 commits), 35 commits over 2 days (2026-04-23 to 2026-04-24), V0.1 "experimental" self-labeled, no pre-built binary. Built on two reverse-engineered Apple interfaces (private `MultitouchSupport`, undocumented `NX_SYSDEFINED`) that Apple can break at any release. Expected fragility, not a security issue.

7. **License: MIT** (`LICENSE`, Copyright 2026 Jinsoo An). Permissive, compatible with local use and with the MIT-licensed Remotastic upstream. Bundled `MultitouchSupport.h` credits Nathan Vander Wilt (the widely redistributed reverse-engineered header).

---

## Per-File Checklist (every file fully read)

| File | Read | What it does |
|---|---|---|
| `build.sh` | ✅ | Single `swiftc` invocation over the 10 Swift sources; links IOKit/CoreGraphics/AudioToolbox/Carbon/AppKit + private MultitouchSupport. No curl/wget/network/remote fetch. |
| `create_app_bundle.sh` | ✅ | Assembles `HyperVibe.app`, writes a static `Info.plist` (bundle id `com.hypervibe.app`, `LSUIElement`, Bluetooth usage strings), ad-hoc codesigns (`--sign -`) with hardened runtime + entitlements. No network, no external identity, no hidden commands. |
| `gen_icon.swift` | ✅ | Procedurally renders PNG icon frames into `HyperVibe.iconset/` (in-repo). Pure CoreGraphics drawing; no I/O beyond writing icon files. |
| `HyperVibe.entitlements` | ✅ | Three keys: `device.bluetooth` (needed), `cs.disable-library-validation` (needed for private fw), `cs.allow-dyld-environment-variables` (likely unnecessary — see non-blocker 1). |
| `Package.swift` | ✅ | SwiftPM manifest, macOS 11+, links system frameworks only (no MultitouchSupport). No external package dependencies. |
| `LICENSE` | ✅ | MIT, Copyright 2026 Jinsoo An. |
| `main.swift` | ✅ | App entry point: creates `NSApplication` + `AppDelegate`, `NSApplicationMain`. |
| `SiriRemoteApp.swift` | ✅ | `AppDelegate` wiring (menu bar, detector, input handler, media-key interceptor, touch handler, accessibility prompt) + `RCDControl` (suspends/restores `com.apple.rcd` via `/bin/launchctl`). No network. |
| `MenuBarManager.swift` | ✅ | Menu bar UI, button/swipe mapping persistence in UserDefaults, synthesizes key/mouse events (`CGEvent`) for mapped actions. Only injects keys, never reads external input. |
| `RemoteDetector.swift` | ✅ | IOKit HID discovery of the Siri Remote (Apple vendor + known product IDs). Defines `rmDebug` → `/tmp/hypervibe.log` (device metadata only). |
| `RemoteInputHandler.swift` | ✅ | Seizes the remote's HID interfaces, identifies buttons, dispatches mapped actions (tap/hold/click/drag). Logs page/usage/value + button name — no typed content. |
| `CursorController.swift` | ✅ | Posts synthetic mouse move/click/drag/scroll `CGEvent`s for trackpad-driven cursor control. Output only. |
| `MediaController.swift` | ✅ | Fabricates `NX_SYSDEFINED` media-key events. **Dead code — never instantiated.** No network. |
| `MediaKeyInterceptor.swift` | ✅ | `.cghidEventTap` on `NX_SYSDEFINED` to intercept+consume media keys; re-enables tap on timeout/sleep. Reads keycode/state only, logs nothing, no keystroke capture. |
| `TouchHandler.swift` | ✅ | Reads Siri Remote trackpad frames via private MultitouchSupport; converts to cursor move / two-finger scroll / tap / swipe gestures. Device-scoped input, synthetic output only. |
| `SystemVolume.swift` | ✅ | CoreAudio volume get/set + `VolumeRevertGuard` (reverts AVRCP-origin volume changes). Logs volume levels. `prewarm()` never called (inert). |
| `MultitouchSupport.h` | ✅ | Reverse-engineered private-framework header (structs + function decls). Credit: Nathan Vander Wilt. Declarations only. |
| `SiriRemote-Bridging-Header.h` | ✅ | One-line bridging header `#import "MultitouchSupport.h"`. |
| `README.md` | ✅ | Accurate docs; matches the code (dual HID/AVRCP paths, NX_SYSDEFINED technique, permissions, `/tmp/hypervibe.log`). No misleading claims. |
| `.gitignore` | ✅ | Ignores build artifacts, `*.log`, `*.icns`, editor/OS cruft. Nothing sensitive tracked. |

*(Binary assets — `banner.png`, `demo.gif`, `*.iconset/*.png`, `Resources/StatusIcon.png`, screenshots, `status-icon.svg` — are non-executable images, not security-reviewed beyond confirming they are image files.)*

---

## Recommendation

**USE_AS_IS**

No blockers. The app does exactly what it claims and nothing else: no network, no exfiltration, no persistence, no backdoors. It is safe to build locally and grant Accessibility + Input Monitoring + Bluetooth. Optional hardening if desired: (a) drop `com.apple.security.cs.allow-dyld-environment-variables` from the entitlements and rebuild to confirm the trackpad still works; (b) if the `/tmp/hypervibe.log` remote-button metadata matters, tighten its permissions or disable `rmDebug` for normal use. Neither is required before use.
