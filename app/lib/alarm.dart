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

  static const String _bundledAssetPath = 'sounds/brew_complete.wav';
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

  /// Fires sound + haptics. Sound starts and is awaited (so haptic platform
  /// calls don't wrest audio focus before playback is established), then
  /// three haptic pulses follow.
  static Future<void> foregroundAlert() async {
    Diagnostics.log('foregroundAlert begin');
    await _playSound();
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 250));
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 250));
    HapticFeedback.heavyImpact();
    Diagnostics.log('foregroundAlert done (3 haptic pulses fired)');
  }

  /// Preview play used by the Settings test button.
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
  static const _channelId = 'brew_complete_v8';
  static const _channelName = 'Brew complete';
  static const _channelDesc = 'Plays a sound when a brew or kettle finishes.';

  /// Explicit channel sound. Without this, `playSound: true` relies on the
  /// device's `Settings.System.DEFAULT_NOTIFICATION_URI` — which can be
  /// "None" / silent on a misconfigured device, producing zero audio for
  /// our notification. Binding our bundled WAV directly means the OS plays
  /// OUR sound regardless of the device's default-notification-sound
  /// setting. (`brew_complete` resolves to res/raw/brew_complete.wav.)
  static const AndroidNotificationSound _channelSound =
      RawResourceAndroidNotificationSound('brew_complete');

  /// Fixed id so reschedules replace, and cancel always works without
  /// tracking per-brew ids.
  static const int _completionNotificationId = 9001;

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

  /// Schedule the OS-side completion notification for [when]. Idempotent —
  /// uses a fixed notification id, so rescheduling replaces. Inexact
  /// scheduling: no exact-alarm permission required, drift is typically
  /// seconds (worst case ~15 min on heavily throttled devices). Good
  /// enough for a brew timer.
  static Future<void> scheduleCompletion({
    required String title,
    required String body,
    required DateTime when,
  }) async {
    try {
      await _ensureOsInit();
      final tzWhen = tz.TZDateTime.fromMillisecondsSinceEpoch(
        tz.UTC,
        when.toUtc().millisecondsSinceEpoch,
      );
      await _plugin.zonedSchedule(
        _completionNotificationId,
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
      Diagnostics.log('OS notif scheduled for $when');
    } catch (e) {
      Diagnostics.log('OS notif schedule FAILED: $e');
    }
  }

  /// Diagnostics: fires the completion notification immediately. Use this
  /// from the Settings screen to verify the OS-side channel sound config
  /// in isolation, without waiting for a brew. If you tap this and hear
  /// nothing, the device's notification path is the source of silence
  /// (channel sound stripped, DND, volume, etc.) — NOT our app code.
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

  /// Cancel the scheduled completion notification if one is pending. If the
  /// notification has already fired and the user hasn't dismissed it, this
  /// removes it from the shade.
  static Future<void> cancelScheduledCompletion() async {
    try {
      await _ensureOsInit();
      await _plugin
          .cancel(_completionNotificationId)
          .timeout(const Duration(seconds: 2));
      Diagnostics.log('OS notif cancelled');
    } catch (e) {
      Diagnostics.log('OS notif cancel FAILED: $e');
    }
  }
}
