# Binky — Privacy Policy

_Last updated: May 16, 2026_

## The short version

Binky does not collect, store, or transmit any personal data. Everything you log
stays on your device. There is no account, no sign-in, no cloud sync, and no
network communication of any kind.

## What data Binky uses

Binky stores the following information locally on your device, using Android's
standard app-private storage:

- The list of drinks you have configured (type, description, default volume,
  brew presets).
- A log of beverages you have recorded (timestamp, drink, volume, notes).
- Your settings (theme mode, kettle time).
- The state of any in-progress brew timer.

This data never leaves your device. It is not accessible to any other app, the
developer, or any third party. Uninstalling Binky permanently deletes all of it.

## What Binky does not do

- **No accounts.** There is no sign-up or login.
- **No network requests.** The app does not have, and does not request,
  the `INTERNET` permission. It cannot communicate with any server.
- **No analytics.** No usage statistics, crash reports, or telemetry are
  collected.
- **No advertising.** No ad SDKs are included; no ads are shown.
- **No third-party data sharing.** Because nothing is collected, nothing is
  shared.
- **No tracking identifiers.** The app does not read your Advertising ID,
  device ID, or any other identifier.

## Permissions Binky requests

Binky requests the following Android permissions:

- **POST_NOTIFICATIONS** — for the brew-complete alert and the persistent
  "Brew in progress" notification (see FOREGROUND_SERVICE below).
- **VIBRATE** — haptic feedback when a brew timer completes.
- **FOREGROUND_SERVICE** + **FOREGROUND_SERVICE_MEDIA_PLAYBACK** — to run
  a small background service while a brew or kettle timer is active. The
  service exists for one reason: to keep the app's audio code alive while
  the device is locked, so the brew-complete sound rings whether or not
  the screen is on. Android requires foreground services to show a
  persistent notification — Binky's is the "Brew in progress" banner that
  appears while a timer is running and disappears when it completes or is
  cancelled.
- **WAKE_LOCK** — paired with the foreground service to keep the CPU
  active just long enough to fire the brew-complete sound.

Binky does **not** request access to your contacts, photos, location,
microphone, camera, files, calendar, exact alarms, or any other personal
data source.

When you choose a custom alert sound (Settings → Alert sound → Choose custom
sound…), Android shows its system file picker and grants Binky temporary
read access to the single file you select. The audio is then copied into
Binky's private app storage and the original picker permission is dropped.
Binky cannot read any other file from your device.

## Sharing your data with others

Binky includes an optional **Export logs to CSV** feature. When you tap
"Export CSV", the app writes a CSV file containing your log entries to your
device's temporary storage and opens the Android system share sheet. From
there, you decide whether to save the file, email it, or send it elsewhere.
Binky itself does not transmit this file anywhere.

## Children's privacy

Binky is suitable for all ages. Since the app collects no personal data, it
also collects no data from children under 13 (or under any other applicable
age threshold).

## Changes to this policy

If this policy ever changes in a way that affects users, the new version will
be published at the same URL as this one, with an updated "Last updated" date.

## Contact

For questions about this policy, contact: app.binky@gmail.com

