# WoW Character Retry

<img src="Assets/AppIcon.png" alt="WoW Character Retry icon" width="160">

A native macOS app that retries creation of your prepared World of Warcraft character when faction population restrictions prevent creation.

## What it does

- Uses your current character options and name without editing them.
- Waits a configurable minimum between attempts (120 seconds by default).
- Recognizes the faction-imbalance message, clicks Okay, and verifies the dialog has disappeared on two readings before continuing.
- Stops after two character-list readings following a submission, checking the requested name when the optional name check is enabled. It never clicks Enter World.
- Pauses on unfamiliar screens or messages instead of guessing.
- Supports longer throttle cooldowns and optional relaunch through Battle.net. After relaunch it pauses so you can restore any unsaved character options.
- Processes screenshots locally in memory with Apple text recognition; requires no API key or extra packages.

## Requirements

Apple Silicon, macOS 14 or newer, Python 3, and Xcode Command Line Tools. WoW must be windowed, visible, and fully on one display.

## Build

Build and test without replacing an installed app:

```sh
python3 build.py --test --output '/tmp/WoW Character Retry.app'
```

To install, quit the existing retry app first, then run:

```sh
python3 build.py --test --output '/Applications/WoW Character Retry.app'
```

Build outside cloud-synced folders: syncing tools may attach metadata that interferes with app signing. The build script locally signs the app and verifies the signature. A rebuild can invalidate earlier macOS permission approvals; finish building before granting access to the final installed copy.

## Use

Open **WoW Character Retry**, prepare your character in WoW, choose the interval, and press **Start**. Approve Screen Recording and Device Control/Accessibility when needed. **Read screen** checks recognition without clicking. **What the app sees (no clicks)** shows the captured image and recognized text.

Click **Stop** or press **Shift–Command–period** to stop. Stop the retry app before editing a name or interacting with character creation yourself.

See the [user guide](docs/USER_GUIDE.md) for setup, timing, cooldowns, privacy, and recovery details.

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/Core.swift` | Screen classification, timing, settings, and success evidence |
| `Sources/ScreenAccess.swift` | Visible-window capture, guarded clicks, and cancellable OCR worker |
| `Sources/OCRHelper.swift` | Apple Vision text recognition from in-memory image data |
| `Sources/App.swift` | Interface, retry loop, and Battle.net recovery |
| `Tests/` | Screen decisions, timing, success guards, OCR, cancellation, timeout, and pipe tests |
| `Assets/` | App icon and editable raster source |
| `build.py` | Compile, test, assemble, and locally sign the app |

## Validation and limits

Version **2.0.2** passed **56 checks**. Live testing verified submission, recognition of the actual faction-imbalance message, dismissal, confirmation that the dialog was gone, and return to the retry countdown. The success guards were tested; successful character creation was not observed during that test session. Actual throttle-triggered Battle.net recovery remains unverified.

The app captures the visible display area occupied by the selected game or launcher window. Keep it unobscured. It does not store screenshots, upload screen data, read credentials, or modify game files. The optional name check depends on text recognition; a cursor or text caret can obscure a name and cause a safe pause.

This is an independent utility and is not affiliated with Blizzard Entertainment.
