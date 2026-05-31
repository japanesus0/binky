# binky

A small Android app for logging beverages and timing brews — tea, coffee,
soda, water, whatever you drink. Everything stays on your device.

## Documentation — start here

Two guides cover everything about binky. Pick the one that matches you:

| If you're... | Read this |
|---|---|
| **A user** — you want to understand every feature, every screen, every setting, and how to actually use the app | 📘 **[User Guide](binky%20-%20User%20Guide.pdf)** |
| **A developer** — you want to know how binky is built: the brew state machine, the two-isolate audio architecture, why audio focus is configured the way it is, the R8 / resource-shrinker fixes, the encrypted storage layer, every dependency choice | 📗 **[Technical Reference](binky%20-%20Technical%20Reference.pdf)** |
| **Mostly interested in privacy and what data the app touches** | 🔒 [PRIVACY_POLICY.md](PRIVACY_POLICY.md) |
| **Looking at the Play Store listing copy** | 📝 [PLAY_LISTING.md](PLAY_LISTING.md) |

> 📄 The User Guide and Technical Reference render directly in your browser
> on GitHub — click and read, no download required. The original Word
> documents are also tracked in `docs/` if you'd rather open them in
> Word. Both stand alone, so read either one without needing context
> from the other. They cover the ground from "what does the chart icon
> do" all the way to "why is the foreground service's audio focus set
> to `gainTransientMayDuck` instead of `gain`."

## What's in the box

- **Five drink categories** (Hot Tea, Cold Tea, Coffee, Soda, Bog Standard
  Water) with user-editable sub-types under each.
- **One-tap logging** — long-press a category on the home screen to log
  one serving of that category's default drink.
- **Brew timer** with bundled or custom alert sound, screen-on override,
  haptic feedback, and a foreground service that keeps the alert ringing
  even when the phone is locked.
- **Kettle timer** as a separate prep step before the brew itself.
- **Weekly summary chart** plus per-day breakdown.
- **History** with swipe-to-delete + Undo and CSV export via the system
  share sheet.
- **Dark mode**, custom alert sound, encrypted local storage.

## Privacy

binky does not collect, transmit, or share any data. The app does not
declare the `INTERNET` permission and cannot reach any server.

- Drinks, log entries, settings, and the in-progress brew are stored
  locally in encrypted app-private storage
  (AES-256-GCM via Android Keystore + EncryptedSharedPreferences).
- No accounts, no sign-in, no cloud sync, no analytics, no advertising,
  no third-party data sharing, no tracking identifiers.
- See [PRIVACY_POLICY.md](PRIVACY_POLICY.md) for the full statement.

## Android permissions

| Permission | Why |
|---|---|
| `POST_NOTIFICATIONS` | Brew-complete alert + the persistent "Brew in progress" foreground-service notification. |
| `VIBRATE` | Haptic feedback when a brew completes. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Keep the Dart isolate alive so the brew sound fires even with the device locked. |
| `WAKE_LOCK` | Paired with the foreground service to keep the CPU active long enough to play audio. |

Permissions explicitly NOT declared: `INTERNET`, `ACCESS_NETWORK_STATE`,
`USE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED`, any storage / media access.

## Tech stack

- Flutter 3.22+ / Dart 3.4+
- Plain `ValueNotifier`s for state — no Provider / Riverpod / Bloc
- `flutter_secure_storage` for the encrypted local store
- `flutter_foreground_task` for the locked-phone alert path
- `flutter_local_notifications` for the OS-scheduled completion notification
- `audioplayers` on the media stream with `gainTransientMayDuck` audio focus
- `wakelock_plus` for the optional keep-screen-on toggle

## Building

```
cd app
flutter pub get
flutter analyze
flutter run                                                # debug
flutter build appbundle --release --obfuscate --split-debug-info=build\symbols
```

The release AAB lands in `build/app/outputs/bundle/release/app-release.aab`.

For signing, copy `app/android/key.properties.template` to
`app/android/key.properties` and fill in your keystore details. The
`key.properties` file is gitignored.

## License

[MIT](LICENSE) — do what you want with this code, just keep the copyright
notice in any substantial copy or fork. The license includes the standard
"no warranty" disclaimer.
