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

  /// User-configured number of times the brew-complete alert should
  /// fire in succession (1–10). Written by the main isolate when the
  /// brew service starts; the service reads it in onStart and uses it
  /// to drive the loop in [BrewTaskHandler._fireExpiry]. Cannot be a
  /// ValueNotifier in this isolate — the service runs in its own Dart
  /// isolate with no shared memory.
  static const String alertRepetitions = 'brew_alert_repetitions';
}

/// Runs in a SEPARATE isolate from the rest of the app. Cannot access
/// app-level state (drinksNotifier, ActiveBrew, SettingsScreen etc.) —
/// everything it needs must be passed via [FlutterForegroundTask.saveData]
/// before the service starts.
class BrewTaskHandler extends TaskHandler {
  DateTime? _endsAt;
  String? _customSoundPath;
  // Repetitions read from FlutterForegroundTask shared data at service
  // start. Default 2 — matches the default in Settings, used as the
  // failsafe on read failure or fresh installs. Range clamped 1–10 to
  // stay in sync with the slider.
  int _alertReps = 2;
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
    final storedReps = await FlutterForegroundTask.getData<int>(
        key: BrewServiceKeys.alertRepetitions);
    if (storedReps != null) {
      _alertReps = storedReps.clamp(1, 10);
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

    // Audio focus: set context ONCE up front rather than per rep — it's
    // process-global state, so setting it inside the loop just wastes
    // calls. gainTransientMayDuck = "ask other audio (the user's music)
    // to lower volume briefly, then release focus and they auto-resume."
    // Plain `gain` would take permanent focus and the music app would
    // NOT auto-resume — see the May 2026 "music override" bug.
    //
    // usage stays on MEDIA (not NOTIFICATION) — the notification stream
    // is frequently silenced on real devices, which makes our ding
    // inaudible even though play() succeeds. Media rides whatever
    // volume the user is hearing music on. See alarm.dart's matching
    // comment for the full reasoning.
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
        ),
      );
    } catch (_) {/* best effort */}

    final reps = _alertReps.clamp(1, 10);
    final Source source = _customSoundPath != null &&
            _customSoundPath!.isNotEmpty
        ? DeviceFileSource(_customSoundPath!)
        : AssetSource('sounds/elle_and_lorelei.wav');

    for (int i = 0; i < reps; i++) {
      if (i > 0) {
        await Future.delayed(const Duration(milliseconds: 400));
      }

      // Vibrate. HapticFeedback is available in background isolates
      // because services.dart's MethodChannel works as long as we've
      // initialized the binding (FlutterForegroundTask does that).
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 250));
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 250));
      HapticFeedback.heavyImpact();

      // Play the brew-complete sound. Each rep gets a fresh AudioPlayer
      // so there's no carried-over audio focus state — same pattern as
      // the main-isolate audio path in alarm.dart.
      final player = AudioPlayer();
      try {
        await player.play(source);
        // Give the file (~760ms) time to finish before the next rep
        // disposes/replaces it. Conservative ~800ms keeps the cycle
        // tight without truncating the tail.
        await Future.delayed(const Duration(milliseconds: 800));
      } catch (_) {
        // best effort — keep iterating so a single bad play doesn't
        // swallow the whole stack
      } finally {
        try { await player.dispose(); } catch (_) {}
      }
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
