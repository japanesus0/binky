import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground-service isolate.
///
/// flutter_foreground_task spawns a separate Dart isolate for the
/// background task, so the entrypoint must be a top-level function marked
/// with `@pragma('vm:entry-point')` (otherwise tree-shaking drops it).
@pragma('vm:entry-point')
void brewTaskCallback() {
  FlutterForegroundTask.setTaskHandler(BrewTaskHandler());
}

/// Keys used to round-trip state through FlutterForegroundTask's data
/// channel (small string-keyed map shared between main and task isolates).
class BrewServiceKeys {
  static const String endsAtMs = 'brew_ends_at_ms';
  static const String customSoundPath = 'brew_custom_sound_path';
  static const String label = 'brew_label';

  /// Written by the main isolate's lifecycle observer. When `true`, the
  /// app's UI is currently resumed in the foreground — meaning its in-app
  /// expiry path (ActiveBrew.handleExpiry → Alarm.foregroundAlert) will
  /// fire audio + haptics itself. The service reads this and SKIPS its own
  /// audio so the user doesn't get a double ding when the app is open and
  /// unlocked at expiry.
  static const String mainIsolateResumed = 'main_isolate_resumed';

  /// User-configured in-app alert volume multiplier (0.0 = mute, 1.0 = the
  /// WAV's natural level). Written by the main isolate when the brew
  /// service starts; the service reads it in onStart and applies it via
  /// player.setVolume() at expiry. Cannot be a ValueNotifier in this
  /// isolate — the service runs in its own Dart isolate with no shared
  /// memory.
  static const String alertGain = 'brew_alert_gain';
}

/// Runs in a SEPARATE isolate from the rest of the app. Cannot access
/// app-level state (drinksNotifier, ActiveBrew, SettingsScreen etc.) —
/// everything it needs must be passed via [FlutterForegroundTask.saveData]
/// before the service starts.
class BrewTaskHandler extends TaskHandler {
  DateTime? _endsAt;
  String? _customSoundPath;
  // Volume multiplier read from FlutterForegroundTask shared data at
  // service start. Default 1.0 (no attenuation) — used both for fresh
  // installs and as the failsafe on read errors. The main isolate writes
  // this in ActiveBrew._startBrewService alongside customSoundPath.
  double _alertGain = 1.0;
  bool _expiryFired = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final endsMs = await FlutterForegroundTask.getData<int>(
        key: BrewServiceKeys.endsAtMs);
    if (endsMs != null) {
      _endsAt = DateTime.fromMillisecondsSinceEpoch(endsMs);
    }
    _customSoundPath = await FlutterForegroundTask.getData<String>(
        key: BrewServiceKeys.customSoundPath);
    final storedGain = await FlutterForegroundTask.getData<double>(
        key: BrewServiceKeys.alertGain);
    if (storedGain != null && storedGain.isFinite) {
      _alertGain = storedGain.clamp(0.0, 1.0).toDouble();
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    if (_expiryFired || _endsAt == null) return;
    if (DateTime.now().isBefore(_endsAt!)) return;

    _expiryFired = true;
    _fireExpiry();
  }

  Future<void> _fireExpiry() async {
    // Is the main isolate currently resumed in the foreground? If so, its
    // banner / TimerScreen tickers will call ActiveBrew.handleExpiry and
    // fire audio + haptics themselves — we must NOT duplicate that here.
    // Default to false on read failure (treat as background → service rings).
    final mainResumed = await FlutterForegroundTask.getData<bool>(
            key: BrewServiceKeys.mainIsolateResumed) ??
        false;

    if (mainResumed) {
      // Main isolate is alive and will fire the ding. Just inform it that
      // expiry happened (in case its own tick hasn't fired yet) and update
      // the persistent notification. NO audio, NO haptics — main owns them.
      FlutterForegroundTask.sendDataToMain('brew_expired_main_will_alert');
      FlutterForegroundTask.updateService(
        notificationTitle: 'Brew complete',
        notificationText: 'Tap to return to the app.',
      );
      return;
    }

    // App is paused / backgrounded / locked. Service owns the alert.
    //
    // Notify the main isolate so when it later resumes it knows the brew
    // was already alerted (suppresses an in-app double ding on unlock).
    FlutterForegroundTask.sendDataToMain('brew_expired');

    // Vibrate. HapticFeedback is available in background isolates because
    // services.dart's MethodChannel works as long as we've initialized the
    // binding (FlutterForegroundTask does this for us).
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 250));
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 250));
    HapticFeedback.heavyImpact();

    // Play the brew-complete sound. Each call uses a fresh AudioPlayer so
    // there's no carried-over audio focus state — same pattern as the
    // main-isolate audio path in alarm.dart.
    final player = AudioPlayer();
    try {
      // Audio focus: gainTransientMayDuck = "ask other audio (e.g. the
      // user's music) to lower its volume briefly, then we'll release
      // focus and they go back to full volume." Using plain `gain` would
      // take permanent focus and the music app would NOT auto-resume.
      //
      // usage stays on MEDIA (not NOTIFICATION) — the notification stream
      // is frequently silenced on real devices, which makes our ding
      // inaudible even though play() succeeds. Media rides whatever
      // volume the user is hearing music on. See alarm.dart's matching
      // comment for the full reasoning.
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
      // Apply the user-configured gain before play so the attack of the
      // file doesn't blip at full volume. Non-fatal on failure — at worst
      // we play at the player's default (1.0).
      try {
        await player.setVolume(_alertGain);
      } catch (_) {/* swallow — gain is best-effort */}
      final Source source = _customSoundPath != null && _customSoundPath!.isNotEmpty
          ? DeviceFileSource(_customSoundPath!)
          : AssetSource('sounds/elle_and_lorelei.wav');
      await player.play(source);
      // Give the sound 10s to finish before disposing the player.
      await Future.delayed(const Duration(seconds: 10));
    } catch (_) {
      // best effort — service must stop regardless
    } finally {
      try { await player.dispose(); } catch (_) {}
    }

    // Update the foreground notification text + stop the service.
    FlutterForegroundTask.updateService(
      notificationTitle: 'Brew complete',
      notificationText: 'Tap to return to the app.',
    );
    // Note: we don't auto-stop the service here. The main isolate stops
    // it when the user taps Done/Cancel (via ActiveBrew.stop/complete).
    // Leaving the service alive keeps the "complete" notification visible.
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Service is being torn down. Nothing to clean up — the player was
    // already disposed in _fireExpiry's finally block.
  }

  @override
  void onReceiveData(Object data) {
    // Main isolate may send us "stop" if the user cancels before expiry —
    // we just acknowledge; the main isolate also calls stopService().
  }

  @override
  void onNotificationPressed() {
    // User tapped the foreground notification. Launch the app.
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationButtonPressed(String id) {/* no action buttons */}

  @override
  void onNotificationDismissed() {/* ongoing notification — shouldn't dismiss */}
}
