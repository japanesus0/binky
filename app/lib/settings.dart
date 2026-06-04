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

/// Multiplier applied to the in-app brew-complete sound. Range 0.0 (muted)
/// to 1.0 (the WAV's natural peak level). audioplayers' setVolume() caps
/// at 1.0 on Android so we cannot software-amplify above unity — to make
/// the alert genuinely louder, raise the file's own loudness in Audacity
/// (or pick a louder custom sound) and leave this slider at 100%.
///
/// Applied in two places:
///   - foreground path: `alarm.dart` _playSound() before player.play().
///   - service-isolate path: `brew_service.dart` _fireExpiry() — the gain
///     is round-tripped through FlutterForegroundTask.saveData under
///     [BrewServiceKeys.alertGain] when the brew service starts.
///
/// The OS-scheduled completion notification (locked-app path) does NOT
/// honor this — it plays at the device's notification-channel volume,
/// independent of our slider. That's the right behavior: the OS-side
/// volume is a system policy the user controls in Settings → Sound.
final ValueNotifier<double> alertGainNotifier = ValueNotifier<double>(1.0);

class Settings {
  static const _themeKey = 'theme_mode';
  static const _kettleKey = 'kettle_minutes';
  static const _customSoundKey = 'custom_alert_sound_path';
  static const _keepScreenOnKey = 'keep_screen_on_during_brew';
  static const _alertGainKey = 'alert_gain';

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
    final kettleStr = await SecureStore.getString(_kettleKey);
    kettleMinutesNotifier.value =
        (kettleStr != null ? int.tryParse(kettleStr) : null) ?? 5;

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

    // Alert gain. Default 1.0 on fresh installs (no attenuation). Parse
    // defensively: any bad / out-of-range value falls back to full volume
    // rather than e.g. accidentally muting the user.
    final gainStr = await SecureStore.getString(_alertGainKey);
    final parsedGain = gainStr != null ? double.tryParse(gainStr) : null;
    alertGainNotifier.value = (parsedGain != null && parsedGain.isFinite)
        ? parsedGain.clamp(0.0, 1.0).toDouble()
        : 1.0;
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    await SecureStore.setString(_themeKey, mode.name);
    themeModeNotifier.value = mode;
  }

  static Future<void> setKettleMinutes(int minutes) async {
    final clamped = minutes.clamp(1, 30);
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

  static Future<void> setAlertGain(double value) async {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    await SecureStore.setString(_alertGainKey, clamped.toString());
    alertGainNotifier.value = clamped;
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
                    Slider(
                      value: minutes.toDouble(),
                      min: 1,
                      max: 30,
                      divisions: 29,
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
          const _SectionHeader('Alert volume'),
          ValueListenableBuilder<double>(
            valueListenable: alertGainNotifier,
            builder: (context, gain, _) {
              final pct = (gain * 100).round();
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('In-app alert volume'),
                        Text('$pct%',
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                    Slider(
                      value: gain,
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      label: '$pct%',
                      onChanged: (v) => Settings.setAlertGain(v),
                      onChangeEnd: (_) => Alarm.playPreview(),
                    ),
                    const Text(
                      'Multiplier on the brew-complete sound played by the '
                      'app and the brew foreground service. 100% is the '
                      "file's natural level; lower it for quieter contexts. "
                      'For louder than 100%, raise the file gain itself or '
                      'pick a louder custom sound below. The OS notification '
                      "that fires when the phone is locked rides the device's "
                      'notification-channel volume and is not affected by '
                      'this slider.',
                      style: TextStyle(fontSize: 12),
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
