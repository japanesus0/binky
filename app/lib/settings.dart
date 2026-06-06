import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'alarm.dart';
import 'diagnostics.dart';
import 'storage.dart' show SecureStore;

// -----------------------------------------------------------------------------
// Reactive notifiers — listen to these to react to setting changes.
// -----------------------------------------------------------------------------

final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.system);

final ValueNotifier<int> kettleMinutesNotifier = ValueNotifier<int>(5);

/// Controls whether [ActiveBrew] enables the keep-screen-on wake lock while
/// a brew is running. Default OFF — leaving an unlocked phone unattended on
/// a counter is a real security risk and most users won't expect a timer
/// app to suppress their lock screen by default. Users who want the
/// kitchen-timer-on-the-counter behavior can opt in via Settings → Brew
/// screen → "Keep screen on while brewing". The foreground service fires
/// the brew-complete audio either way; this toggle only affects the
/// screen-lock behavior.
final ValueNotifier<bool> keepScreenOnDuringBrewNotifier =
    ValueNotifier<bool>(false);

/// File path of the user-chosen custom alert sound, or null when the bundled
/// default should be used. [Alarm] reads from this whenever it plays the
/// completion sound.
final ValueNotifier<String?> customAlertSoundPathNotifier =
    ValueNotifier<String?>(null);

/// Number of times the brew-complete alert plays in succession when a
/// brew expires. Range 1–10, default 2.
///
/// Repetition is the practical knob for "make sure the user notices" —
/// raising raw loudness has hard limits (audioplayers.setVolume caps at
/// 1.0; software amplification past the file's natural peak just clips
/// the waveform), and a single ding is easy to miss in a noisy or
/// distracted context. Playing the same ding 2–3 times in a row catches
/// attention reliably without distortion.
///
/// Applied in all three alert paths:
///   - foreground path: alarm.dart foregroundAlert() loops N times with
///     a short gap between cycles. Each cycle is audio + 3 haptic
///     pulses, matching the original single-ding pattern.
///   - service-isolate path: brew_service.dart _fireExpiry() loops the
///     same audio+haptic cycle. Reps round-trip through
///     FlutterForegroundTask.saveData under
///     [BrewServiceKeys.alertRepetitions] at brew start.
///   - OS-scheduled completion notification: alarm.dart scheduleCompletion
///     schedules N stacked notifications 1 second apart (base id +
///     iteration index). The device's notification channel rings each
///     one. Cancellation sweeps all 10 possible ids regardless of
///     current setting so changes mid-brew can't leak stale alerts.
///
/// Mid-loop dismissal: when the user taps Done/Cancel on an active brew,
/// ActiveBrew calls Alarm.abortAlert() which sets a flag the foreground
/// loop checks between cycles. The service-isolate loop cannot be
/// aborted from outside (different isolate, no shared memory), but in
/// practice the user can only dismiss from inside the resumed app, in
/// which case the in-app guard already prevented the service from
/// firing in the first place.
final ValueNotifier<int> alertRepetitionsNotifier = ValueNotifier<int>(2);

class Settings {
  static const _themeKey = 'theme_mode';
  static const _kettleKey = 'kettle_minutes';
  static const _customSoundKey = 'custom_alert_sound_path';
  static const _keepScreenOnKey = 'keep_screen_on_during_brew';
  static const _alertRepsKey = 'alert_repetitions';
  // Deprecated key from an earlier closed-test build (50–150% gain
  // slider that pre-amplified PCM). Removed on load so persisted
  // installs don't carry dead bytes; safe to delete this constant once
  // closed test cycles past the boost-slider release.
  static const _deprecatedAlertGainKey = 'alert_gain';

  /// Loads all settings from encrypted storage into the notifiers above.
  /// Call once during app startup, after SecureStore migration, before the
  /// first frame.
  static Future<void> load() async {
    final t = await SecureStore.getString(_themeKey);
    themeModeNotifier.value = switch (t) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    // Kettle time. Clamp to the slider's current range (1–15) on load
    // — if a tester persisted a higher value under the old 1–30 slider,
    // a raw read would feed an out-of-range value into the Slider widget
    // and trip its asserts. Bad / missing values fall back to the
    // default 5 min (one electric kettle to boil).
    final kettleStr = await SecureStore.getString(_kettleKey);
    final parsedKettle = kettleStr != null ? int.tryParse(kettleStr) : null;
    kettleMinutesNotifier.value =
        (parsedKettle != null) ? parsedKettle.clamp(1, 15) : 5;

    final keepScreenStr = await SecureStore.getString(_keepScreenOnKey);
    // Default OFF on fresh installs (security: don't suppress the lock
    // screen by default). Existing installs preserve whatever the user
    // last set — the SecureStore value persists across upgrades and
    // takes precedence over this fallback.
    keepScreenOnDuringBrewNotifier.value =
        keepScreenStr == null ? false : keepScreenStr == 'true';

    // Custom sound — only honor the path if the file is still on disk.
    final soundPath = await SecureStore.getString(_customSoundKey);
    if (soundPath != null && await File(soundPath).exists()) {
      customAlertSoundPathNotifier.value = soundPath;
    } else {
      customAlertSoundPathNotifier.value = null;
      if (soundPath != null) {
        // Stored path is broken — clear it so we don't keep checking.
        await SecureStore.remove(_customSoundKey);
      }
    }

    // Alert repetitions. Default 2 on fresh installs — one ding is
    // easy to miss; two is the cheapest "I notice it" without being
    // pushy. Clamped 1–10. Bad/missing values silently fall back to
    // the default rather than failing loudly.
    final repsStr = await SecureStore.getString(_alertRepsKey);
    final parsedReps = repsStr != null ? int.tryParse(repsStr) : null;
    alertRepetitionsNotifier.value =
        (parsedReps != null) ? parsedReps.clamp(1, 10) : 2;
    // Clean up the deprecated boost-slider key. No-op if absent.
    await SecureStore.remove(_deprecatedAlertGainKey);
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    await SecureStore.setString(_themeKey, mode.name);
    themeModeNotifier.value = mode;
  }

  static Future<void> setKettleMinutes(int minutes) async {
    // Clamp must match the slider's max (currently 15). Any persisted
    // values above 15 from earlier closed-test builds get clamped down
    // on next save — a minor regression for the ~0 users who had it
    // above 15 anyway. The notifier itself is loaded with the same
    // ceiling so the slider can't be initialized off-scale.
    final clamped = minutes.clamp(1, 15);
    await SecureStore.setString(_kettleKey, clamped.toString());
    kettleMinutesNotifier.value = clamped;
  }

  static Future<void> setKeepScreenOnDuringBrew(bool on) async {
    await SecureStore.setString(_keepScreenOnKey, on ? 'true' : 'false');
    keepScreenOnDuringBrewNotifier.value = on;
  }

  static Future<void> setCustomAlertSoundPath(String? path) async {
    if (path == null) {
      await SecureStore.remove(_customSoundKey);
    } else {
      await SecureStore.setString(_customSoundKey, path);
    }
    customAlertSoundPathNotifier.value = path;
  }

  static Future<void> setAlertRepetitions(int value) async {
    final clamped = value.clamp(1, 10);
    await SecureStore.setString(_alertRepsKey, clamped.toString());
    alertRepetitionsNotifier.value = clamped;
  }
}

// -----------------------------------------------------------------------------
// SettingsScreen — full-page UI listing every preference.
// -----------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _themeLabel(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Follow system',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };

  /// Opens the OS file picker. Copies the picked file into the app's
  /// documents directory so we own a stable, readable path (the original
  /// pick URI from Android's scoped storage is not durable across reboots).
  Future<void> _pickCustomSound(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        withData: true,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      final bytes = picked.bytes;
      if (bytes == null) {
        messenger.clearSnackBars();
        messenger.showSnackBar(
          const SnackBar(
            duration: Duration(seconds: 3),
            content: Text('Could not read that audio file.'),
          ),
        );
        return;
      }

      // Persist into app docs so the path survives the system file picker's
      // session permissions.
      final docs = await getApplicationDocumentsDirectory();
      final ext = (picked.extension ?? 'audio').toLowerCase();
      final dest = File('${docs.path}/custom_alert.$ext');
      // Wipe any older custom sound (different extension) so we don't leak.
      for (final f in docs.listSync()) {
        if (f is File &&
            f.path.contains('/custom_alert.') &&
            f.path != dest.path) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      await dest.writeAsBytes(bytes, flush: true);
      await Settings.setCustomAlertSoundPath(dest.path);

      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text('Using "${picked.name}" as the alert sound.'),
        ),
      );
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text('Pick failed: $e'),
        ),
      );
    }
  }

  Future<void> _revertToDefault(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final path = customAlertSoundPathNotifier.value;
    await Settings.setCustomAlertSoundPath(null);
    if (path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 2),
        content: Text('Reverted to default alert sound.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Appearance'),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeModeNotifier,
            builder: (context, mode, _) {
              return RadioGroup<ThemeMode>(
                groupValue: mode,
                onChanged: (v) {
                  if (v != null) Settings.setThemeMode(v);
                },
                child: Column(
                  children: [
                    for (final m in ThemeMode.values)
                      RadioListTile<ThemeMode>(
                        title: Text(_themeLabel(m)),
                        value: m,
                      ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('Brew screen'),
          ValueListenableBuilder<bool>(
            valueListenable: keepScreenOnDuringBrewNotifier,
            builder: (context, on, _) {
              return SwitchListTile(
                title: const Text('Keep screen on while brewing'),
                subtitle: const Text(
                  'Stops the device from auto-locking while a brew or '
                  'kettle timer is running. The brew-complete sound still '
                  'fires when locked either way.',
                ),
                value: on,
                onChanged: (v) => Settings.setKeepScreenOnDuringBrew(v),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('Kettle'),
          ValueListenableBuilder<int>(
            valueListenable: kettleMinutesNotifier,
            builder: (context, minutes, _) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Kettle Time'),
                        Text('$minutes min',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    // Range 1–15 min covers every realistic household kettle
                    // scenario (electric: 2–5 min, gas stovetop: 4–7 min,
                    // weak burner with 3 L: 10–15 min). Anything longer is
                    // truly fringe (samovars, solar kettles, etc.) and is
                    // better served by the brew timer's custom duration
                    // than by stretching this slider to a 30-stop throw
                    // that's hard to land precisely.
                    Slider(
                      value: minutes.toDouble(),
                      min: 1,
                      max: 15,
                      divisions: 14,
                      label: '$minutes min',
                      onChanged: (v) =>
                          Settings.setKettleMinutes(v.round()),
                    ),
                    const Text(
                      'Used by the "Kettle Time" button on brewable drinks.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('Alert repetitions'),
          ValueListenableBuilder<int>(
            valueListenable: alertRepetitionsNotifier,
            builder: (context, reps, _) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Times to ding'),
                        Text(reps == 1 ? '1 time' : '$reps times',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    // Integer slider 1–10, 9 divisions for 10 stops.
                    // No preview-on-release — the existing
                    // "Simulate brew-complete alert" button below in
                    // Diagnostics fires the full N-repetition pattern
                    // and is the right place to audition the rhythm.
                    Slider(
                      value: reps.toDouble(),
                      min: 1,
                      max: 10,
                      divisions: 9,
                      label: '$reps',
                      onChanged: (v) =>
                          Settings.setAlertRepetitions(v.round()),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('Alert sound'),
          ValueListenableBuilder<String?>(
            valueListenable: customAlertSoundPathNotifier,
            builder: (context, customPath, _) {
              final isDefault = customPath == null;
              final filename = isDefault
                  ? 'Default (built-in bell)'
                  : customPath.split(RegExp(r'[\\/]')).last;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            filename,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play preview',
                          onPressed: () => Alarm.playPreview(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.audio_file_outlined),
                          label: const Text('Choose custom sound…'),
                          onPressed: () => _pickCustomSound(context),
                        ),
                        if (!isDefault)
                          TextButton.icon(
                            icon: const Icon(Icons.refresh),
                            label: const Text('Revert to default'),
                            onPressed: () => _revertToDefault(context),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Any short audio file (.mp3, .wav, .ogg, .m4a). '
                      'Plays once when a brew or kettle timer completes.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
          const _SectionHeader('Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('View diagnostic log'),
            subtitle: const Text(
                'Recent events from audio, notifications, brew lifecycle.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.volume_up_outlined),
            title: const Text('Simulate brew-complete alert (in-app audio)'),
            subtitle: const Text(
                'Fires sound + 3 haptic pulses via the in-app path. '
                'Tests audioplayers / haptics only.'),
            onTap: () {
              Diagnostics.log('Settings: simulate in-app alert tapped');
              Alarm.foregroundAlert();
            },
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('Test OS notification (fires now)'),
            subtitle: const Text(
                'Posts the brew-complete notification immediately. '
                'If you don\'t hear a sound, the device is suppressing it '
                '(channel sound, DND, volume) — not the app.'),
            onTap: () {
              Diagnostics.log('Settings: test OS notification tapped');
              Alarm.testFireCompletionNotification();
            },
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
