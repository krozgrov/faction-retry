# WoW Character Retry 2.0.7

Installed in **Applications → WoW Character Retry**. Requires Apple Silicon and macOS 14 or newer. The app uses Apple's built-in screen and text recognition tools; it needs no API key or extra software.

## Start with your current character

Leave WoW in windowed mode with your chosen character options and name prepared. The current faction-imbalance dialog can stay open. Set **Time between attempts** (120 seconds by default), then click **Start**.

The app reads the selected WoW window, recognizes the final **Finish** button, and submits the prepared character. It never edits your name, race, class, appearance, or other character options.

When it sees **“This faction is currently unavailable on this ruleset due to population imbalance,”** it clicks **Okay** and requires two readings confirming that the dialog is gone. If it remains, it retries Okay up to three times, then pauses. Once dismissed, it waits for the configured interval, and tries again. If the app starts with that message already open, it waits a full interval before the next submission.

After pressing Finish, the app allows up to 30 seconds for WoW to return its response. The editor can remain visible during that wait; the app does not send another Finish click. Before submission the app reads the full prepared name. After a submission, two consecutive character-list readings containing that full name stop the run. The app does not click **Enter World**. An optional name check is available under **More settings**; the full submitted name is always checked before reporting success.

## One-time access setup

**Start never opens permission settings.** If access is missing, the status explains it and shows **Enable access**. Use that action and approve the installed app in macOS. You may need Touch ID or your Mac password. **Read screen** verifies recognition without sending any clicks.

Screen reading and sending clicks are separate macOS permissions. The permission panes may be called **Device Control and Data Access/Accessibility** and **Screen & System Audio Recording**, depending on macOS. An earlier build's permission can become invalid when its executable changes; use the installed 2.0 copy consistently.

## Throttle errors and relaunches

Recognized messages such as **“Creation of that type of character is currently throttled”** or **“Too many attempts”** receive a longer cooldown. The initial cooldown defaults to 10 minutes and is adjustable. Repeated restart recoveries double that wait, up to 24 hours.

With automatic relaunch enabled, the app:

1. Normally quits only the selected WoW client. It does not force-quit the game.
2. Waits out the saved cooldown.
3. Opens Battle.net and verifies that the selected game-version label directly above **Play** matches the configured version (currently **WoW: Forever**).
4. Clicks **Play** and waits for the selected WoW client to appear.
5. Pauses for you to restore the prepared character and name if the restart discarded them. Click **Start** to resume.

It cannot reconstruct unsaved customization after a restart. It does not guess your choices or automatically pass login, update, or other unexpected screens. The default maximum is three automatic restarts; **More settings** has an explicit recovery-counter reset that retains the cooldown.

With relaunch disabled, throttle messages are dismissed and the app waits for the cooldown before another attempt.

## Stop and timing

Click **Stop**, close the app, or press **Shift–Command–period**. Stop also terminates any running text-recognition helper. The last-attempt time and cooldown survive app restarts and manual stops. The configured interval is a minimum; reading the screen or waiting for WoW can make an attempt later.

Only one app instance can run at a time. Manual typing or clicks in the game pause retries. Locking the Mac, sleep, and switching users also pause the run. Waking or unlocking does not resume it; press Start when ready. Settings are editable while stopped. The app can bring WoW forward at each attempt, allowing you to use other apps between attempts. Turn that option off to require WoW to stay active. A covered or moved window, unknown dialog, disconnection, failed reader, or unrecognized screen pauses the run instead of sending an uncertain click. The app keeps the display awake while a run is active.

## Privacy and diagnostics

Capture is filtered to the selected WoW or Battle.net window. Other windows are excluded from the image. The app checks for windows covering game content before and after capture; if coverage or movement is detected, it pauses and discards the image before recognition. Keep the window fully on one display and unobscured. Image data stays in memory and is passed to a local helper; it is never uploaded or saved as a screenshot. The helper has a 12-second deadline and is killed on timeout or cancellation, so a stalled reader cannot freeze the interface.

**Activity** shows what happened. **What the app sees (no clicks)** displays the captured image and recognized text locally for diagnosis. Stop, safety pauses, and completion clear the retained image and recognized text. **Show log** opens the local activity log, which is limited to 1 MiB and readable only by your Mac user account. Oversized old logs are trimmed on their next write. The app does not modify game files or store account credentials.

## Validation

Version 2.0.7 passed 99 automated checks, including delayed server replies and prevention of duplicate submissions while waiting, covering the observed faction message through real OCR, character-editor recognition, unknown dialogs, throttle detection, selected-version verification, configurable timing, persisted cooldowns, success guards, large OCR results, helper cancellation, and helper timeout. Its layout, saved duration, and Start behavior were also checked in the running Mac app. Live screen recognition correctly identified the exact faction-imbalance dialog and the prepared character editor. Stop was also tested during an interrupted 8 MB image transfer. Window checks were tested with other monitors and the small screen-sharing badge, while windows actually covering the button block input.

Live testing confirmed that version 2.0.2 closed the actual imbalance dialog and verified its absence on two readings. Version 2.0.2 captures the visible game area, improves recognition of gold text, and verifies dialog dismissal instead of assuming a sent click succeeded. A gold-and-cyan arcane retry-clock icon is installed.

The throttle message itself has not occurred during live testing. Battle.net recovery is implemented, but an actual throttle-triggered relaunch remains unverified.

The source archive includes a build script and tests. It uses only Swift and macOS frameworks.
