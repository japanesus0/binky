import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'diagnostics.dart';
import 'settings.dart';

/// Alert feedback when a brew or kettle timer expires.
///
/// Two complementary paths produce the ding:
///
///   1. **OS-scheduled completion notification** (this file's
///      `scheduleCompletion` / `cancelScheduledCompletion`). Fires whether
///      the app is in foreground, backgrounded, or with the device locked.
///      Plays the device's default notification sound on a high-importance
///      channel — no bundled custom sound, no exact-alarm permission. This
///      is the path that survives the device sleeping the app's process.
///
///   2. **In-app audioplayers + haptics** (`foregroundAlert`). Fires when
///      the in-app expiry detector catches the brew expiring while the
///      user is actively in the app. Uses default audioplayers config
///      (media stream, media volume) — confirmed working in foreground.
///
/// ActiveBrew.handleExpiry coordinates these: when the in-app path runs,
/// it cancels the pending OS notification to avoid a double ding. If the
/// OS already fired (background/locked case), handleExpiry detects the
/// late delta and suppresses the in-app sound.
class Alarm {
  // ---------------------------------------------------------------------------
  // Audio (in-app foreground)
  // ---------------------------------------------------------------------------

  static const String _bundledAssetPath = 'sounds/elle_and_lorelei.wav';
  static bool _audioContextReady = false;

  /// Explicitly resets the global audioplayers context.
  ///
  /// Critical: setAudioContext is process-sticky. Earlier iterations of
  /// this file briefly set it to USAGE_ALARM and USAGE_NOTIFICATION (the
  /// usageType param), both of which silenced playback on test devices
  /// (alarm volume at 0, etc.). Simply *removing* the call later doesn't
  /// undo the previous state. So we now EXPLICITLY set it the first time
  /// audio is needed.
  ///
  /// Audio focus is `gainTransientMayDuck`: when the brew ding plays we
  /// only ask other audio apps (e.g. the user's music) to LOWER their
  /// volume briefly. As soon as our ~1s sound ends and focus is released
  /// they return to full volume. Plain `gain` was used here previously
  /// and caused music apps to stop and never resume — see the May 2026
  /// "music override" bug.
  ///
  /// usage/contentType STAY on MEDIA/MUSIC: routing to USAGE_NOTIFICATION
  /// puts our sound on the notification stream, which users frequently
  /// silence ("de-notificationed phone") — making the ding inaudible
  /// even though play() returns success. The media stream is what the
  /// user's volume rocker controls when nothing else is playing, so it's
  /// the reliable path. Combined with TRANSIENT_MAY_DUCK we get both
  /// "always audible" and "doesn't kill the user's music."
  static Future<void> _ensureAudioContext() async {
    if (_audioContextReady) return;
    _audioContextReady = true;
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
      Diagnostics.log(
          'audio context set: MEDIA/MUSIC/TRANSIENT_DUCK');
    } catch (e) {
      Diagnostics.log('audio context failed: $e');
    }
  }

  /// Set by [abortAlert] when the user dismisses an active brew while a
  /// multi-rep alert loop is in flight. Each cycle of the loop checks
  /// this between steps and bails early. Reset to false at the start of
  /// every [foregroundAlert] call so a stale dismiss can't poison a
  /// future alert.
  static bool _abortAlert = false;

  /// Tell any in-flight [foregroundAlert] to stop after its current
  /// step. Called by [ActiveBrew.stop]/[ActiveBrew.complete] so a Done
  /// or Cancel tap halts the dinging immediately rather than making the
  /// user wait through the remaining reps. Service-isolate audio cannot
  /// be aborted from here (different isolate, no shared memory); in
  /// practice that doesn't matter because the service only fires the
  /// alert when the main isolate is paused, and the user can't tap
  /// Done from outside the app.
  static void abortAlert() {
    _abortAlert = true;
  }

  /// Fires the alert pattern N times in succession, where N is the
  /// user's [alertRepetitionsNotifier] setting (clamped 1–10). Each
  /// cycle is: audio start, then three 250ms-spaced haptic pulses
  /// overlapping the audio playback, then a short tail before the next
  /// cycle starts. _playSound() returns once playback STARTS (not when
  /// it ends), so the haptics overlap the audio rather than queueing
  /// after it — that's the same pattern we used pre-rep-loop, just
  /// repeated.
  static Future<void> foregroundAlert() async {
    _abortAlert = false;
    final reps = alertRepetitionsNotifier.value.clamp(1, 10);
    Diagnostics.log('foregroundAlert begin (reps=$reps)');
    for (int i = 0; i < reps; i++) {
      if (_abortAlert) {
        Diagnostics.log('foregroundAlert aborted at rep ${i + 1}/$reps');
        return;
      }
      if (i > 0) {
        // Inter-cycle gap. With a ~760ms WAV and 500ms of haptics
        // overlap, the previous ding is finishing right about now;
        // this 400ms gap gives a clear "ding ... ding" rhythm rather
        // than a continuous noise.
        await Future.delayed(const Duration(milliseconds: 400));
        if (_abortAlert) return;
      }
      await _playSound();
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 250));
      if (_abortAlert) return;
      HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 250));
      if (_abortAlert) return;
      HapticFeedback.heavyImpact();
      // Tail: gives the audio time to finish before the next cycle's
      // _playSound() disposes the still-playing player (which would
      // cut the sound off abruptly).
      await Future.delayed(const Duration(milliseconds: 300));
    }
    Diagnostics.log('foregroundAlert done ($reps reps fired)');
  }

  /// Preview play used by the Settings test button. Plays once,
  /// regardless of the reps setting — this exists for the
  /// custom-sound preview where you just want to hear the file. Use
  /// the "Simulate brew-complete alert" diagnostic button instead if
  /// you want to audition the full N-rep alert rhythm.
  static Future<void> playPreview() {
    Diagnostics.log('Settings: preview play tapped');
    return _playSound();
  }

  /// We do NOT use a single static AudioPlayer. Per the diagnostic logs,
  /// after an OS-scheduled notification fires its own sound, the static
  /// player's audio focus is lost and subsequent play() calls return
  /// "successfully" but produce no audible output. A fresh player per
  /// call re-requests audio focus cleanly via the global audio context.
  ///
  /// The player is held in [_activePlayer] just long enough to be
  /// disposed if a new play comes in (so rapid-fire previews don't pile
  /// up overlapping audio). The cleanup Timer disposes it after a
  /// generous window (10s) regardless.
  static AudioPlayer? _activePlayer;
  static Timer? _activePlayerCleanup;

  static Future<void> _playSound() async {
    final source = _currentSource();
    final sourceLabel = source is DeviceFileSource
        ? 'custom (${source.path})'
        : 'bundled asset';
    Diagnostics.log('_playSound: source=$sourceLabel');

    // Dispose any in-flight player so a new one starts cleanly. Cancels
    // both the previous Timer and the previous player.
    _activePlayerCleanup?.cancel();
    final previous = _activePlayer;
    _activePlayer = null;
    if (previous != null) {
      // Fire-and-forget — disposing while playing cuts the audio off,
      // which is what we want when the user retriggers rapidly.
      previous.dispose().catchError((_) {});
    }

    AudioPlayer? player;
    try {
      await _ensureAudioContext();
      player = AudioPlayer();
      _activePlayer = player;
      // Safety net — dispose after 10s even if onPlayerComplete doesn't fire.
      _activePlayerCleanup = Timer(const Duration(seconds: 10), () {
        if (_activePlayer == player) _activePlayer = null;
        player?.dispose().catchError((_) {});
      });
      // Natural-completion disposal — beats the safety net for short sounds.
      unawaited(
        player.onPlayerComplete.first.then((_) {
          if (_activePlayer == player) _activePlayer = null;
          player?.dispose().catchError((_) {});
        }).catchError((_) {/* swallow */}),
      );

      await player.play(source).timeout(const Duration(seconds: 2));
      Diagnostics.log('_playSound: play() returned successfully');
    } catch (e, st) {
      Diagnostics.log('_playSound FAILED: $e');
      if (kDebugMode) debugPrint('$st');
      // Hand the broken player back for disposal.
      if (player != null) {
        try { await player.dispose(); } catch (_) {}
      }
    }
  }

  static Source _currentSource() {
    final customPath = customAlertSoundPathNotifier.value;
    if (customPath != null && customPath.isNotEmpty) {
      return DeviceFileSource(customPath);
    }
    return AssetSource(_bundledAssetPath);
  }

  // ---------------------------------------------------------------------------
  // OS-scheduled completion notification (for locked / backgrounded states)
  // ---------------------------------------------------------------------------

  static final _plugin = FlutterLocalNotificationsPlugin();
  // Channel ID bumped to elle_and_lorelei_v2 because the WAV file was
  // re-rendered louder (Audacity loudness pass — see the file-side gain
  // change shipped alongside the in-app gain slider). Android caches the
  // sound URI per channel ID forever once created — without bumping the
  // ID, existing testers' devices would keep playing the OLD quieter file
  // on the OS-locked path (the in-app foreground path reads from the
  // asset bundle every play, so it picks up the new file immediately
  // regardless of channel ID). v1 → v2 forces a fresh channel.
  //
  // History: brew_complete_v8 → elle_and_lorelei_v1 (rename + dedication).
  // elle_and_lorelei_v1 → elle_and_lorelei_v2 (file re-rendered louder).
  static const _channelId = 'elle_and_lorelei_v2';
  static const _channelName = 'Elle and Lorelei';
  static const _channelDesc = 'Plays a sound when a brew or kettle finishes.';

  /// Explicit channel sound. Without this, `playSound: true` relies on the
  /// device's `Settings.System.DEFAULT_NOTIFICATION_URI` — which can be
  /// "None" / silent on a misconfigured device, producing zero audio for
  /// our notification. Binding our bundled WAV directly means the OS plays
  /// OUR sound regardless of the device's default-notification-sound
  /// setting. (`elle_and_lorelei` resolves to res/raw/elle_and_lorelei.wav.)
  static const AndroidNotificationSound _channelSound =
      RawResourceAndroidNotificationSound('elle_and_lorelei');

  /// Base id for scheduled completion notifications. The N-repetition
  /// scheduler fans out across ids [_completionNotificationId ..
  /// _completionNotificationId + _maxAlertReps - 1] — one per ding,
  /// each scheduled 1 second after the previous. Cancellation sweeps
  /// the whole range so changes to the reps setting between brews
  /// can't leave stale alerts queued under higher indices.
  static const int _completionNotificationId = 9001;
  static const int _maxAlertReps = 10;

  static bool _osInitialized = false;

  static Future<void> _ensureOsInit() async {
    if (_osInitialized) return;
    _osInitialized = true;
    try {
      tzdata.initializeTimeZones();
      const init = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(
        const InitializationSettings(android: init),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Channel uses the device's DEFAULT notification sound (no custom
      // sound URI). This was the root cause of the previous "channel
      // exists, sound preview shows 'App provided sound', but no audio"
      // saga — the bundled WAV reference broke on some OEMs. Defaulting
      // to the device's own notification ringtone sidesteps that.
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
        playSound: true,
        sound: _channelSound, // explicit — don't rely on device default
        enableVibration: true,
      ));
      await android?.requestNotificationsPermission();
    } catch (_) {/* best effort */}
  }

  /// Schedule the OS-side completion notification(s) for [when]. Fans
  /// out the user's repetitions setting (1–10) into a stack of
  /// individual notifications, each 1 second after the previous. Each
  /// rings the channel sound; the Android system groups stacked
  /// entries in the shade. Idempotent within a single brew: cancel
  /// before reschedule via [cancelScheduledCompletion] if you need to
  /// rebuild the stack with new timing.
  ///
  /// Inexact scheduling: no exact-alarm permission required, drift is
  /// typically seconds (worst case ~15 min on heavily throttled
  /// devices). Good enough for a brew timer.
  static Future<void> scheduleCompletion({
    required String title,
    required String body,
    required DateTime when,
  }) async {
    try {
      await _ensureOsInit();
      final reps = alertRepetitionsNotifier.value.clamp(1, _maxAlertReps);
      for (int i = 0; i < reps; i++) {
        final repWhen = when.add(Duration(seconds: i));
        final tzWhen = tz.TZDateTime.fromMillisecondsSinceEpoch(
          tz.UTC,
          repWhen.toUtc().millisecondsSinceEpoch,
        );
        await _plugin.zonedSchedule(
          _completionNotificationId + i,
          title,
          body,
          tzWhen,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDesc,
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.reminder,
              playSound: true,
              sound: _channelSound,
              enableVibration: true,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
      Diagnostics.log(
          'OS notif scheduled for $when ($reps rep${reps == 1 ? '' : 's'})');
    } catch (e) {
      Diagnostics.log('OS notif schedule FAILED: $e');
    }
  }

  /// Diagnostics: fires the completion notification immediately. Use this
  /// from the Settings screen to verify the OS-side channel sound config
  /// in isolation, without waiting for a brew. If you tap this and hear
  /// nothing, the device's notification path is the source of silence
  /// (channel sound stripped, DND, volume, etc.) — NOT our app code.
  ///
  /// Fires a SINGLE notification regardless of the user's repetitions
  /// setting — this exists to verify the OS sound path works at all,
  /// not to audition the full rep stack. The simulate-in-app diagnostic
  /// button covers the rep rhythm via the in-app loop.
  static Future<void> testFireCompletionNotification() async {
    try {
      await _ensureOsInit();
      await _plugin.show(
        _completionNotificationId,
        'binky test notification',
        'If you hear this ding, OS notification audio works on this device.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDesc,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            playSound: true,
            sound: _channelSound,
            enableVibration: true,
          ),
        ),
      );
      Diagnostics.log('test OS notification posted (id=$_completionNotificationId)');
    } catch (e) {
      Diagnostics.log('test OS notification FAILED: $e');
    }
  }

  /// Cancel the entire scheduled completion stack — sweeps all
  /// [_maxAlertReps] ids even if the current setting is lower, so a
  /// reduction in reps between brews can't leave stale alerts queued
  /// under higher indices. Cancel on a non-existent id is a no-op in
  /// flutter_local_notifications, so the extra cancels are free.
  static Future<void> cancelScheduledCompletion() async {
    try {
      await _ensureOsInit();
      for (int i = 0; i < _maxAlertReps; i++) {
        try {
          await _plugin
              .cancel(_completionNotificationId + i)
              .timeout(const Duration(seconds: 2));
        } catch (_) {/* swallow per-id — keep sweeping */}
      }
      Diagnostics.log('OS notif stack cancelled (ids cleared)');
    } catch (e) {
      Diagnostics.log('OS notif cancel FAILED: $e');
    }
  }
}
