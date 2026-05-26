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
/// a brew is running. Default true (matches the pre-toggle behavior — phone
/// stays unlocked on the counter for kitchen-timer use). Off lets the
/// screen auto-lock; the foreground service still fires the brew-complete
/// audio either way.
final ValueNotifier<bool> keepScreenOnDuringBrewNotifier =
    ValueNotifier<bool>(true);

/// File path of the user-chosen custom alert sound, or null when the bundled
/// default should be used. [Alarm] reads from this whenever it plays the
/// completion sound.
final ValueNotifier<String?> customAlertSoundPathNotifier =
    ValueNotifier<String?>(null);

class Settings {
  static const _themeKey = 'theme_mode';
  static const _kettleKey = 'kettle_minutes';
  static const _customSoundKey = 'custom_alert_sound_path';
  static const _keepScreenOnKey = 'keep_screen_on_during_brew';

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
    // Default true if unset (preserves pre-toggle behavior).
    keepScreenOnDuringBrewNotifier.value =
        keepScreenStr == null ? true : keepScreenStr == 'true';

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
          const SnackBar(content: Text('Could not read that audio file.')),
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
        SnackBar(content: Text('Using "${picked.name}" as the alert sound.')),
      );
    } catch (e) {
      messenger.clearSnackBars();
      messenger.showSnackBar(SnackBar(content: Text('Pick failed: $e')));
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
      const SnackBar(content: Text('Reverted to default alert sound.')),
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
