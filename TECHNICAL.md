# Binky — Technical Reference

_For your own review. Describes what the code actually does, file by file._

---

## 1. Overview

Binky is a single-purpose Android app: log beverages and time brews. Built in Flutter, targets Android only. All data is stored locally on the device — there is no backend, no account system, and the app does not request the `INTERNET` permission, so it cannot make network requests.

- **Language:** Dart (Flutter 3.22+ / Dart 3.4+)
- **Platform:** Android (min SDK 21, target SDK follows Flutter default)
- **Architecture:** Single-Activity Flutter app, no native channels beyond what plugins provide
- **State management:** Plain `ValueNotifier`s + static service classes — no Provider / Riverpod / Bloc
- **Persistence:** `shared_preferences` (single key-value store, JSON-encoded values)
- **Background work:** OS-scheduled alarms via `flutter_local_notifications` — no foreground service

---

## 2. File layout

All Dart source lives in [app/lib/](app/lib/). Nine files total.

| File | Role | Approx. lines |
|---|---|---|
| [main.dart](app/lib/main.dart) | App entry, root `MaterialApp`, `HomeScreen`, active-brew banner widget | 290 |
| [storage.dart](app/lib/storage.dart) | `Drink` + `LogEntry` data models, `DrinksStore` + `LogStore` (CRUD) | 220 |
| [screens.dart](app/lib/screens.dart) | `DrinkScreen`, `TimerScreen`, `SummaryScreen`, weekly chart | 440 |
| [active_brew.dart](app/lib/active_brew.dart) | `ActiveBrewState` + `ActiveBrew` controller (the timer state machine) | 180 |
| [alarm.dart](app/lib/alarm.dart) | Thin wrapper around `flutter_local_notifications`: channels, scheduling, tap callback | 150 |
| [settings.dart](app/lib/settings.dart) | `Settings` (load/save) + `SettingsScreen` UI | 130 |
| [history.dart](app/lib/history.dart) | `HistoryScreen` — list + swipe-delete + edit dialog | 200 |
| [drinks_editor.dart](app/lib/drinks_editor.dart) | `DrinksEditorScreen` + new/edit drink form | 250 |
| [export.dart](app/lib/export.dart) | `LogExporter.shareCsv()` — CSV gen + OS share sheet | 50 |

Android platform code is the standard Flutter scaffold (`MainActivity.kt` is a 5-line `FlutterActivity` subclass). All app logic is in Dart.

---

## 3. Data model

The drink model is a two-level hierarchy:

- **Category** — fixed list of 5 (Hot Tea, Cold Tea, Coffee, Soda, Bog Standard Water). Hardcoded; not user-editable.
- **Drink (sub-type)** — many per category (e.g. Earl Grey, Diet Pepsi). User-editable.

### `DrinkCategory` — top-level grouping

```dart
class DrinkCategory {
  final String name;                 // also used as the Drink.type value
  final IconData icon;               // Material icon shown on Home + editor
  final double defaultVolume;        // applied to "Other..." sub-types
  final bool brewable;               // gate the brew chips + Kettle button
  final List<int> defaultBrewTimes;  // preset minutes for new sub-types
}
```

`const drinkCategories` ships 5 entries with these defaults: Hot Tea (16oz, brewable, [3,5,7]), Cold Tea (20oz), Coffee (16oz, brewable, [1,2,3]), Soda (12oz), Bog Standard Water (20oz). `categoryByName(s)` looks up by name.

### `Drink` — a beverage sub-type

```dart
class Drink {
  final int id;                 // stable identifier
  final String type;            // MUST match a DrinkCategory.name
  final String description;     // sub-type name ("Earl Grey", "Diet Coke")
  final double defaultVolume;   // oz; pre-fills the volume field
  final bool brewable;          // overrides category default per-drink
  final List<int> brewTimes;    // preset minutes (e.g. [3, 5, 7])
  final bool isDefault;         // pre-selected sub-type within its category
}
```

The 13 seeded sub-types (4 Hot Tea, 2 Cold Tea, 3 Coffee, 3 Soda, 1 Water) are inserted on first launch. Default sub-types (`isDefault: true`): Green Tea, Triple Berry, Cream & Sugar, Diet Pepsi, Water.

`DrinksStore.upsert` enforces the **exactly-one-default-per-category** invariant: setting `isDefault: true` on one drink demotes any sibling in the same category.

### `LogEntry` — one recorded beverage

```dart
class LogEntry {
  final int id;                 // unique; timestamp.microsecondsSinceEpoch at log time
  final DateTime timestamp;     // when it was logged
  final int drinkId;            // FK to Drink
  final String type;            // denormalized — survives drink deletion
  final String description;     // denormalized
  final double volume;          // oz
  final String notes;           // user-entered, may be empty
}
```

`type` and `description` are **denormalized** intentionally — if you delete a drink, existing log entries keep their original labels and don't become "Unknown."

### `ActiveBrewState` — the one in-progress brew, if any

```dart
class ActiveBrewState {
  final DateTime endsAt;            // computed at start (now + duration)
  final Duration originalDuration;  // for progress ring math
  final String appBarTitle;         // "Brewing Hot tea" / "Kettle for Hot tea"
  final String alarmTitle;          // "Brew complete" / "Kettle ready"
  final String alarmBody;           // "Hot tea is ready." / "Time to brew..."
  final String doneLabel;           // "Done — log it" / "Done"
  final int? alarmId;               // OS notification id for the completion alarm
  final int? drinkIdToLog;          // if non-null, log this drink when Done is tapped
  final double? volume;             // captured at brew start (kettle has null)
  final String notes;               // captured at brew start
}
```

Brews and kettle timers share the same type. They differ only in whether `drinkIdToLog` is set.

---

## 4. Storage layer

All persistent state lives in one `SharedPreferences` instance under these keys:

| Key | Type | Contents |
|---|---|---|
| `drinks_v2` | String | JSON array of `Drink` objects (with `isDefault` field) |
| `brew_log` | StringList | List of JSON-encoded `LogEntry` objects |
| `theme_mode` | String | `"system"` \| `"light"` \| `"dark"` |
| `kettle_minutes` | int | 1–30, default 5 |
| `active_brew_v1` | String? | JSON-encoded `ActiveBrewState`, or absent if no brew |

**Migration policy:** keys are versioned (`_v<n>` suffix). When the schema changes incompatibly we bump the suffix; the previous-version key is left orphaned in storage (trivial garbage — a few hundred bytes) and ignored. The current bump `drinks_v1 → drinks_v2` was triggered by the category restructure and `isDefault` field addition.

**Backward compatibility:** `LogEntry.fromJson` detects pre-id-field entries (old schema where `id` was the drink id) and derives a synthetic LogEntry id from the timestamp. Existing log entries with old type strings (`"Tea"`, `"Coffee"`) continue to load — they show in Summary as their own grouped sections (not merged into the new category names), which is harmless.

---

## 5. Reactive state — global notifiers

The app avoids dependency-injection frameworks. Instead, four global `ValueNotifier`s are read by screens via `ValueListenableBuilder`. All mutations go through service methods that update both the persisted store and the notifier.

| Notifier | Type | Source of truth |
|---|---|---|
| `drinksNotifier` | `List<Drink>` | [storage.dart](app/lib/storage.dart) |
| `activeBrewNotifier` | `ActiveBrewState?` | [active_brew.dart](app/lib/active_brew.dart) |
| `themeModeNotifier` | `ThemeMode` | [settings.dart](app/lib/settings.dart) |
| `kettleMinutesNotifier` | `int` | [settings.dart](app/lib/settings.dart) |

Trade-off: this approach is simple but doesn't scale to a complex app. For a single-purpose app like this, it's the right call. If features grow, swapping to Riverpod is a few-hour refactor.

---

## 6. Screens and navigation

```
HomeScreen
├── AppBar
│   ├── 📊 Summary icon       → SummaryScreen
│   └── ⋮ Overflow menu
│       ├── History           → HistoryScreen
│       ├── Edit drinks       → DrinksEditorScreen
│       └── Settings          → SettingsScreen
├── _ActiveBrewBanner          (only when ActiveBrew.current != null)
│   └── tap                   → TimerScreen
└── Categories list (5 fixed)
    ├── tap on category       → CategoryScreen
    └── long-press            → quick-log category's default sub-type + Undo snackbar

CategoryScreen
├── Sub-types in this category (⭐ marks default)
│   ├── tap                   → DrinkScreen
│   └── long-press            → quick-log this sub-type + Undo snackbar
└── "Other..."                → _OtherDrinkDialog
                                 ├── Cancel
                                 └── Continue
                                     ├── unchecked Save → synthetic Drink (one-off, not persisted)
                                     └── checked Save   → DrinksStore.upsert + push(DrinkScreen)

DrinkScreen
├── Volume, brew chips (incl. Custom slider), notes
├── "Brew X min, then log"    → ActiveBrew.start + pushReplacement(TimerScreen)
├── "Log without brewing"     → LogStore.logDrink + pop
└── "Kettle Time (N min)"     → ActiveBrew.start + push(TimerScreen)
                                 (returns HERE; doneLabel = "Brew now")

TimerScreen
├── Reads activeBrewNotifier (does NOT own state)
├── Vsync Ticker → ms-precision countdown
├── Cancel                    → ActiveBrew.stop + pop(null)
└── doneLabel button          → ActiveBrew.complete + pop(true)
                                 (kettle caller awaits pop(true) → SnackBar nudge)

SummaryScreen
├── AppBar: 📅 "today" icon   → jump to current week
├── _WeekNavigator
│   ├── ‹ chevron             → previous week
│   ├── 📆 date label         → showDatePicker → jump to picked week
│   └── › chevron             → next week (disabled at current week)
├── _WeeklyChart (7 bars, Sun→Sat of selected week)
└── Daily breakdown cards (only days within selected week)

HistoryScreen
├── Reverse-chronological entries (Dismissible)
├── tap                      → edit volume/notes dialog
├── swipe                    → delete + Undo snackbar
└── share icon               → LogExporter.shareCsv → OS share sheet

DrinksEditorScreen
├── List grouped by category (section headers, ⭐ on each default)
├── tap drink                → drink form (Category dropdown + isDefault toggle)
├── swipe drink              → delete + Undo
├── FAB                      → "Add to which category?" picker → drink form
└── overflow                 → Reset to defaults (reseeds full 13-drink list)

SettingsScreen
├── Appearance: theme RadioGroup (System / Light / Dark)
└── Kettle: minutes slider (1–30)
```

**Navigation strategy:**

- **Brew → Timer** uses `pushReplacement` so backing out of TimerScreen lands on Home, not back on DrinkScreen (you've already logged the drink; nothing to do back on DrinkScreen).
- **Kettle → Timer** uses plain `push` so popping returns to DrinkScreen, where the Brew button is one tap away. The TimerScreen `_onDone` returns `true` via `Navigator.pop(true)` so the kettle caller can show a "Water's hot" SnackBar nudge. The brew caller never reads this value (pushReplacement doesn't surface it).
- **Notification taps** use `pushAndRemoveUntil((route) => route.isFirst)` — clears the stack back to Home, then pushes TimerScreen. Keeps the stack clean regardless of where the user was. Trade-off: a backgrounded kettle that completes via notification tap doesn't return to DrinkScreen on Done — it lands on Home instead.
- A global `navigatorKey` is held in [main.dart](app/lib/main.dart) so the notification-tap callback (which has no `BuildContext`) can push.

---

## 7. The brew system (the meaty part)

This is the most complex piece, so it gets its own section.

### 7.1 States

`ActiveBrew` is a singleton with three logical states:

| State | Check | Meaning |
|---|---|---|
| **Idle** | `ActiveBrew.current == null` | No brew running. |
| **Running** | `current != null && !current.expired` | Counting down. |
| **Expired (awaiting acknowledgment)** | `current != null && current.expired` | Timer hit zero; user hasn't tapped Done or Cancel yet. |

`expired` is a computed property: `endsAt.isBefore(DateTime.now())`.

### 7.2 Transitions

| From | To | Trigger | What happens |
|---|---|---|---|
| Idle | Running | `ActiveBrew.start(...)` | Schedule OS completion alarm via `Alarm.scheduleCompletion()`; show ongoing chronometer notification via `Alarm.showOngoing()`; persist `ActiveBrewState` to `active_brew_v1`; emit on `activeBrewNotifier`. |
| Running | Running | none | Passive — `expired` flips to true automatically when `DateTime.now()` crosses `endsAt`. The OS scheduled alarm fires the user notification at this moment. |
| Running | Idle | `ActiveBrew.stop()` | Triggered by TimerScreen Cancel button or by another `ActiveBrew.start` that needs to displace this brew. Cancels OS alarm + ongoing notification, clears persisted state. |
| Expired | Idle | `ActiveBrew.complete()` | Triggered by TimerScreen Done button. If `drinkIdToLog != null`, writes a `LogEntry` first. Cancels alarms, clears persisted state. |

### 7.3 The OS alarm

`Alarm.scheduleCompletion()` calls `_plugin.zonedSchedule(...)` with:

- `androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle` — fires at the exact target time even in Doze mode. Combined with the `USE_EXACT_ALARM` manifest permission, this is auto-granted for timer-class apps on API 33+.
- `category: AndroidNotificationCategory.alarm` — tells Android this is an alarm, gets ringtone priority.
- `importance: Importance.max` + `priority: Priority.high` — heads-up banner + sound + vibration, even with the app in the foreground.
- Channel: `brew_timer_alerts`.

The alarm is scheduled on the OS's `AlarmManager`, independent of our app process. If you swipe the app from recents, the alarm still fires.

### 7.4 The ongoing notification

`Alarm.showOngoing()` posts a persistent notification with:

- `ongoing: true, autoCancel: false` — sticky; can't be swiped away.
- `usesChronometer: true, chronometerCountDown: true, when: endsAt.millisecondsSinceEpoch` — Android's notification system renders a live MM:SS countdown without any periodic updates from us.
- `importance: Importance.low, playSound: false` — visible in the shade, no sound, no heads-up. Separate channel (`brew_timer_ongoing`) from the alert channel.
- Fixed ID (`9001`) so successive brews replace the previous chronometer in place.

The OS-driven chronometer is the reason a backgrounded or even force-killed brew continues to show an accurate countdown in the shade.

### 7.5 The in-app Ticker

While TimerScreen is mounted, a `Ticker` (vsync-aligned via `SingleTickerProviderStateMixin`) fires up to 60 fps. Each tick:

1. Reads `ActiveBrew.current.remaining`.
2. If positive, updates `_remaining` and rebuilds → ms-precision UI countdown.
3. If non-positive, stops the ticker, fires `Alarm.foregroundAlert()` (3 haptic pulses), and cancels the ongoing notification.

When the screen is backgrounded, Flutter pauses frame callbacks → Ticker pauses. On resume, it ticks again and `remaining` reflects real elapsed time (since we compute from `endsAt - now`, not by decrement).

**Important:** `TimerScreen.dispose()` does **not** call `ActiveBrew.stop()`. Backing out of the screen leaves the brew running. Only Cancel and Done resolve the brew.

### 7.6 Persistence and restoration

`ActiveBrew._persist()` writes the state to `active_brew_v1` on every transition. `ActiveBrew.load()` runs once at app startup ([main.dart](app/lib/main.dart) `main()`). On load:

- If no persisted state → idle. Nothing to do.
- If persisted state exists and `endsAt` is more than 1 hour in the past → discarded as stale.
- Otherwise → state restored. If the OS alarm is still pending (i.e. the app was killed but not for too long), it'll fire normally. If the alarm was lost (rare; reboot or aggressive battery-saver), the user sees the `_ActiveBrewBanner` showing "Ready — tap to finish" and can tap it to acknowledge.

### 7.7 Notification tap → TimerScreen deep-link

[alarm.dart](app/lib/alarm.dart) exposes `onNotificationTap` as a static `void Function()?` setter. [main.dart](app/lib/main.dart) registers `_handleNotificationTap` into it. The handler:

1. Checks `ActiveBrew.current != null` (nothing to navigate to otherwise).
2. Uses the global `navigatorKey` to call `pushAndRemoveUntil(MaterialPageRoute(TimerScreen()), (r) => r.isFirst)`.

This works for both runtime taps (app already running) and cold-launch taps (app was killed). Cold-launch is handled by a post-first-frame call to `Alarm.appLaunchedFromNotification()` which returns true if `flutter_local_notifications` reports this process was started by a notification tap.

### 7.8 Replace-running-brew safeguard

`DrinkScreen._confirmReplaceIfRunning()` runs before any `ActiveBrew.start()` call. If a brew is already in flight, it shows a Material dialog: **"A brew is already running. [Keep running] [Replace]"**. Keep running aborts the new start; Replace lets it proceed (which silently calls `ActiveBrew.stop()` inside `ActiveBrew.start()` first).

This is the only confirmation dialog in the app — destructive overwrites of in-flight work warrant it. Other destructive actions (delete log entry, delete drink) use the swipe-to-delete + snackbar-undo pattern instead.

### 7.9 Brew vs. Kettle distinction

Both are `ActiveBrew` instances; the differences are entirely in how the calling screen wires the navigation and what the post-completion action looks like.

| Aspect | Brew | Kettle |
|---|---|---|
| `drinkIdToLog` | set to the current drink | `null` |
| Done button label | `"Done — log it"` | `"Brew now"` |
| Done action | `ActiveBrew.complete()` → writes a `LogEntry` | `ActiveBrew.complete()` → no log written (drinkIdToLog is null) |
| Navigation into TimerScreen | `pushReplacement` — DrinkScreen is dropped | `push` — DrinkScreen stays on the stack underneath |
| Post-completion landing | Home (DrinkScreen was replaced) | Back on DrinkScreen, with a "Water's hot — ready to brew X" SnackBar |
| Caller awaits result? | No (pushReplacement) | Yes — checks for `true` from `Navigator.pop(true)` to trigger the SnackBar |

The intent: a Brew is the terminal action — once it's done, you've drunk the drink, the log is written, you go home. A Kettle is a prep step — once it's done, you're meant to start the actual brew, so the user is dropped back at DrinkScreen with the Brew button one tap away.

---

## 8. Notifications

Two channels, created on first `Alarm.init()` call:

| Channel ID | Importance | Sound | Vibration | Purpose |
|---|---|---|---|---|
| `brew_timer_alerts` | `max` | yes | yes | One-shot completion alarm. Heads-up banner. |
| `brew_timer_ongoing` | `low` | no | no | Persistent chronometer countdown. Shade-only, silent. |

`Alarm.init()` is lazy — first called when a brew starts (heavy timezone-data load, would block cold start otherwise). The `POST_NOTIFICATIONS` runtime prompt appears here, on Android 13+. If the user denies it, alarms still get scheduled but won't display — the user will need to keep the app in foreground to know when a brew is done. The in-app haptic alert still fires.

---

## 9. Theming and settings

Material 3 with `ColorScheme.fromSeed(seedColor: const Color(0xFF6B4423))` — coffee brown. Both light and dark variants are generated from the same seed. `themeMode` is driven by `themeModeNotifier`, defaulting to `ThemeMode.system`. The `BinkyApp` widget wraps `MaterialApp` in a `ValueListenableBuilder<ThemeMode>` so theme changes rebuild the whole tree on `Settings.setThemeMode()`.

Kettle time defaults to 5 minutes, range 1–30. The Kettle Time button label updates reactively because [screens.dart](app/lib/screens.dart) wraps its button in a `ValueListenableBuilder<int>`.

No other settings exist. Anything user-customizable goes through `Settings` for consistency.

---

## 10. Permissions

| Permission | Manifest entry | Justification | Runtime prompt |
|---|---|---|---|
| `POST_NOTIFICATIONS` | yes | Show brew alarm + ongoing chronometer | Yes, on first brew start (Android 13+) |
| `USE_EXACT_ALARM` | yes | Precise timing for `exactAllowWhileIdle` scheduling | Auto-granted for timer-class apps on API 33+ |
| `VIBRATE` | yes | Haptic feedback on brew complete | Normal permission, auto-granted |

Permissions **not** declared (each is a deliberate omission):

- `INTERNET` — the app cannot make any network call
- `ACCESS_NETWORK_STATE` — irrelevant if no internet
- `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, `READ_MEDIA_*` — CSV export uses the app's own temp dir + the OS share sheet
- `WAKE_LOCK` — Ticker only runs when the screen is on; we don't need to keep the device awake
- `RECEIVE_BOOT_COMPLETED` — alarms don't survive reboot (see Limitations)

The manifest also sets `android:allowBackup="false"` and `android:usesCleartextTraffic="false"`.

---

## 11. Build configuration

[android/app/build.gradle.kts](app/android/app/build.gradle.kts):

- `applicationId = "com.binkyapp"`, `namespace = "com.binkyapp"`
- `compileSdk = flutter.compileSdkVersion` (resolves to current; ~35)
- `minSdk = flutter.minSdkVersion` (typically 21)
- `targetSdk = flutter.targetSdkVersion`
- `isCoreLibraryDesugaringEnabled = true` (required by `flutter_local_notifications`)
- `desugar_jdk_libs:2.1.4` as a dependency
- Release `buildType`:
  - `isMinifyEnabled = true` (R8)
  - `isShrinkResources = true`
  - ProGuard rules from `proguard-rules.pro`
  - Signing config reads from `android/key.properties` if present, falls back to debug keystore otherwise

[android/app/proguard-rules.pro](app/android/app/proguard-rules.pro) keeps:

- All `io.flutter.**` classes (engine + plugin runtime)
- `com.dexterous.**` (flutter_local_notifications — uses reflection for notification dispatch)
- `GeneratedPluginRegistrant` (plugin entry point)
- Enum reflection for serialized notification responses

The Dart layer adds another obfuscation pass via:

```
flutter build appbundle --release --obfuscate --split-debug-info=build\symbols
```

The `build/symbols/` directory (per-architecture `.symbols` files) is what you'd use to de-obfuscate crash reports. **Keep it locally; don't commit it.**

---

## 12. Dependencies

Five production deps, one dev-only. None make network calls.

| Package | Version | Maintainer | Purpose |
|---|---|---|---|
| `shared_preferences` | ^2.2.3 | flutter.dev team | Local key-value store |
| `flutter_local_notifications` | ^17.2.3 | dexter / fluttercommunity | Alarms + ongoing notification |
| `timezone` | ^0.9.4 | srawlins (pure Dart) | Required by flutter_local_notifications for zoned scheduling |
| `share_plus` | ^9.0.0 | Flutter Community Plus Plugins | OS share sheet for CSV |
| `path_provider` | ^2.1.3 | flutter.dev team | Temp directory for CSV file |
| `flutter_launcher_icons` | ^0.14.1 (dev) | fluttercommunity | Generates Android mipmap icons from a source PNG |

`flutter_local_notifications` is the only "heavy" dependency. It pulls in a Kotlin codebase, an AndroidX dependency tree, and ~1 MB of timezone data. All other deps are small.

---

## 13. Behavior under unusual conditions

| Condition | Behavior |
|---|---|
| **App backgrounded mid-brew** | Ticker pauses. OS chronometer notification continues to count down. Completion alarm fires on schedule. On foreground return, Ticker resumes, computes remaining from `endsAt - now`. |
| **App swiped from recents mid-brew** | Process killed. OS alarm + chronometer continue (they're system-managed, not in our process). On next launch, `ActiveBrew.load()` rehydrates state from disk. |
| **App force-stopped from Settings** | Process killed AND all `AlarmManager` alarms cleared. Persisted state survives but the alarm is gone. On next launch, the banner will show "Ready — tap to finish" and the user can acknowledge manually. Worst case: silent miss. |
| **Phone reboot mid-brew** | Same as force-stop. We do not have `RECEIVE_BOOT_COMPLETED` to re-schedule on boot. |
| **Notification permission denied** | Alarms still get scheduled, just don't display. User must keep the app foreground to see the in-app countdown. Haptic feedback still fires on completion. |
| **Two brews started in quick succession** | The replace-confirmation dialog gates this. If the user taps Replace, `ActiveBrew.start()` calls `stop()` internally before scheduling the new one. |
| **Brew expires >1 hour in the past during app load** | `ActiveBrew.load()` discards as stale. The user sees a clean slate. |
| **User edits volume on a drink mid-brew (after starting it)** | No effect on the running brew — `volume` was captured into `ActiveBrewState` at start time. The new value applies to the *next* brew. |
| **Drink deleted while a brew for it is running** | `ActiveBrew.complete()` falls back to a stub `Drink` constructed from the captured state, so the log entry still gets written with the original description. |
| **CSV export with zero entries** | Produces a CSV with just the header row and opens the share sheet. Empty but valid. |
| **Device locale changes mid-brew** | No effect; we use ISO timestamps and English-only strings. |

---

## 14. Known limitations / explicitly deferred

These are conscious decisions, not bugs:

1. **No reboot survival.** AlarmManager alarms are cleared on phone reboot. Fix would be `RECEIVE_BOOT_COMPLETED` + a boot receiver that re-schedules from persisted state. Skipped because typical brew durations are minutes, not hours.

2. **No notification action buttons.** Currently you must open the app to cancel a running brew. Adding "Cancel" and "Snooze" buttons directly on the ongoing notification is a known follow-up and would be ~30 lines.

3. **Single concurrent brew.** Starting a second brew requires confirming replacement. Multi-brew support would mean a list UI, per-brew alarm IDs (already in place), a different banner widget (banner-list), and is probably overkill for this app's scope.

4. **No cloud sync, no account, no backup.** Intentional. CSV export covers data portability. `allowBackup="false"` means even Android's adb-backup can't extract the database.

5. **Android only.** iOS code paths exist (Flutter is cross-platform) but iOS-specific notification config, permission delegates, and platform channels haven't been wired up. Adding iOS support is a separate project.

6. **No internationalization.** All strings are English literals. Adding i18n means adopting `flutter_localizations` and refactoring every UI string into an `AppLocalizations` lookup. Deferred.

7. **No unit tests.** Test file is a placeholder. The app's logic-heavy classes (`ActiveBrew`, `DrinksStore`, `LogStore`) are pure Dart and easy to test if you ever want to.

8. **Dart obfuscation symbols are local-only.** If you publish a build, save the corresponding `build/symbols/` directory somewhere safe (1Password, encrypted drive) per release. Without those symbols, Play Console crash reports will be unreadable.

---

## 15. Build & deploy quick reference

Day-to-day development:
```
flutter run
```

Static analysis:
```
flutter analyze
```

Generate launcher icons (after replacing source PNGs):
```
dart run flutter_launcher_icons
```

Release AAB for Play Store:
```
flutter clean
flutter pub get
flutter analyze
flutter build appbundle --release --obfuscate --split-debug-info=build\symbols
```

Output lands in `build/app/outputs/bundle/release/app-release.aab`.

Bump `version` in [pubspec.yaml](app/pubspec.yaml) for every Play upload — the build code (the number after `+`) must be strictly greater than the previous upload, or Play will reject it.

---

## 16. Repo layout summary

```
├── PRIVACY_POLICY.md            ← public-facing, host before Play submission
├── PLAY_LISTING.md              ← copy-paste source for Play Console
├── TECHNICAL.md                 ← this file
└── app\                         ← Flutter project
    ├── lib\                     ← all Dart source (9 files)
    ├── assets\                  ← icon source PNGs (icon.png, icon-foreground.png)
    ├── android\
    │   ├── app\
    │   │   ├── build.gradle.kts ← signing, R8, applicationId
    │   │   ├── proguard-rules.pro
    │   │   └── src\main\
    │   │       ├── AndroidManifest.xml  ← permissions, app metadata
    │   │       └── kotlin\com\binkyapp\MainActivity.kt
    │   ├── key.properties.template  ← copy to key.properties (gitignored)
    │   └── gradle.properties
    ├── pubspec.yaml             ← deps, version, launcher_icons config
    └── test\                    ← placeholder test
```
