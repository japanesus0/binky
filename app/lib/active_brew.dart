import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'alarm.dart';
import 'brew_service.dart';
import 'diagnostics.dart';
import 'settings.dart'
    show
        alertGainNotifier,
        customAlertSoundPathNotifier,
        keepScreenOnDuringBrewNotifier;
import 'storage.dart';

/// Immutable snapshot of an active brew. The interesting state is in
/// [endsAt]; everything else is metadata used to drive the timer screen and
/// (optionally) log a drink entry when the user taps Done.
///
/// No OS-notification scheduling state is held here — the app intentionally
/// uses no system notifications. Alerts on expiry are in-app only.
class ActiveBrewState {
  final DateTime endsAt;
  final Duration originalDuration;
  final String appBarTitle;
  final String alarmTitle;
  final String alarmBody;
  final String doneLabel;

  // If set, calling [ActiveBrew.complete] will log the named drink with the
  // captured volume/notes. If null, Done just dismisses (kettle-style).
  //
  // We carry type/description denormalized so one-off drinks (created via
  // "Other..." without "Save for later") still log correctly even though
  // they were never persisted in DrinksStore.
  final int? drinkIdToLog;
  final String? drinkTypeForLog;
  final String? drinkDescriptionForLog;
  final double? volume;
  final String notes;

  const ActiveBrewState({
    required this.endsAt,
    required this.originalDuration,
    required this.appBarTitle,
    required this.alarmTitle,
    required this.alarmBody,
    required this.doneLabel,
    this.drinkIdToLog,
    this.drinkTypeForLog,
    this.drinkDescriptionForLog,
    this.volume,
    this.notes = '',
  });

  Duration get remaining => endsAt.difference(DateTime.now());
  bool get expired =>
      remaining.isNegative || remaining.inMilliseconds <= 0;

  Map<String, dynamic> toJson() => {
        'endsAt': endsAt.toIso8601String(),
        'originalDurationMs': originalDuration.inMilliseconds,
        'appBarTitle': appBarTitle,
        'alarmTitle': alarmTitle,
        'alarmBody': alarmBody,
        'doneLabel': doneLabel,
        'drinkIdToLog': drinkIdToLog,
        'drinkTypeForLog': drinkTypeForLog,
        'drinkDescriptionForLog': drinkDescriptionForLog,
        'volume': volume,
        'notes': notes,
      };

  factory ActiveBrewState.fromJson(Map<String, dynamic> j) => ActiveBrewState(
        endsAt: DateTime.parse(j['endsAt'] as String),
        originalDuration:
            Duration(milliseconds: (j['originalDurationMs'] as int?) ?? 0),
        appBarTitle: j['appBarTitle'] as String,
        alarmTitle: j['alarmTitle'] as String,
        alarmBody: j['alarmBody'] as String,
        doneLabel: j['doneLabel'] as String,
        // Legacy field `alarmId` from pre-strip versions is ignored if present.
        drinkIdToLog: j['drinkIdToLog'] as int?,
        drinkTypeForLog: j['drinkTypeForLog'] as String?,
        drinkDescriptionForLog: j['drinkDescriptionForLog'] as String?,
        volume: (j['volume'] as num?)?.toDouble(),
        notes: (j['notes'] as String?) ?? '',
      );
}

/// Reactive global brew. Any widget can `ValueListenableBuilder` this and
/// rebuild when a brew starts, stops, or completes.
final ValueNotifier<ActiveBrewState?> activeBrewNotifier =
    ValueNotifier<ActiveBrewState?>(null);

/// Mirrors the main isolate's foreground/background state into
/// FlutterForegroundTask shared data so the service isolate can decide
/// whether to fire its own audio at brew expiry (skip when main is
/// resumed — main will fire it). Without this, both isolates ring and
/// the user hears a double ding.
class _BrewLifecycleSync extends WidgetsBindingObserver {
  static final _BrewLifecycleSync _instance = _BrewLifecycleSync._();
  factory _BrewLifecycleSync() => _instance;
  _BrewLifecycleSync._();

  bool _installed = false;
  AppLifecycleState? _lastLogged;

  void install() {
    if (_installed) return;
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
    final initial = WidgetsBinding.instance.lifecycleState;
    _logIfChanged(initial);
    _write(initial);
  }

  void _write(AppLifecycleState? state) {
    final resumed = state == AppLifecycleState.resumed;
    // Fire-and-forget — saveData is async but cheap; we don't need to
    // block UI on it. Errors are non-fatal: worst case the service
    // double-dings once, which is what we had before. saveData returns
    // Future<bool>, so the catchError callback must return bool.
    FlutterForegroundTask.saveData(
      key: BrewServiceKeys.mainIsolateResumed,
      value: resumed,
    ).catchError((_) => false);
  }

  /// Log lifecycle transitions to Diagnostics. Skip duplicate states
  /// (Android occasionally re-fires the same state) to keep the log
  /// readable. The persistent log makes these markers useful even after
  /// a process kill — we can see e.g. that the app was paused, then
  /// hours later launched into a "=== app launched ===" without ever
  /// hitting "resumed", which would point at a launch-gate intercept.
  void _logIfChanged(AppLifecycleState? state) {
    if (state == null || state == _lastLogged) return;
    _lastLogged = state;
    Diagnostics.log('lifecycle: ${state.name}');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _logIfChanged(state);
    _write(state);
  }
}

class ActiveBrew {
  static const _key = 'active_brew_v1';

  /// Guard so [handleExpiry] only fires its side effects once per brew.
  /// ONLY reset by start() for the next brew. NOT reset by stop()/complete()
  /// — doing so previously opened a ~80ms race where the home-banner Timer
  /// re-fired handleExpiry between the flag clear and the state clear.
  static bool _expiryHandled = false;

  // (Previously had a _wasPausedAtOrAfterExpiry flag to suppress in-app
  // ding on resume after paused expiry, assuming the OS notification had
  // already alerted the user. Removed because on devices where OS notif
  // sound is suppressed (DND, channel sound stripped, etc.) the user
  // would get NO ding at all. Better to risk a redundant ding than miss
  // the alert entirely.)

  /// Starts the foreground service that keeps our Dart isolate alive while
  /// a brew is running. Without this, Android pauses our process when the
  /// device locks, and the brew-complete sound never fires.
  static Future<void> _startBrewService({
    required String appBarTitle,
    required DateTime endsAt,
  }) async {
    try {
      await FlutterForegroundTask.saveData(
        key: BrewServiceKeys.endsAtMs,
        value: endsAt.millisecondsSinceEpoch,
      );
      final customSound = customAlertSoundPathNotifier.value;
      if (customSound != null && customSound.isNotEmpty) {
        await FlutterForegroundTask.saveData(
          key: BrewServiceKeys.customSoundPath,
          value: customSound,
        );
      } else {
        await FlutterForegroundTask.removeData(
          key: BrewServiceKeys.customSoundPath,
        );
      }
      // Volume multiplier — round-trips through shared data because the
      // service runs in a separate isolate. Read by BrewTaskHandler.onStart
      // and applied via player.setVolume() in _fireExpiry. The service
      // captures whatever the value is at brew-start; subsequent slider
      // changes mid-brew don't retroactively apply (acceptable — typical
      // brew is < 10 min and users rarely re-tune during one).
      await FlutterForegroundTask.saveData(
        key: BrewServiceKeys.alertGain,
        value: alertGainNotifier.value.clamp(0.0, 1.0).toDouble(),
      );
      final endTimeLabel =
          '${endsAt.hour.toString().padLeft(2, '0')}:${endsAt.minute.toString().padLeft(2, '0')}';
      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 256,
          notificationTitle: appBarTitle,
          notificationText: 'Ready at $endTimeLabel',
          callback: brewTaskCallback,
        );
      }
      Diagnostics.log('foreground service STARTED for $appBarTitle');
    } catch (e) {
      Diagnostics.log('foreground service start FAILED: $e');
    }
  }

  static Future<void> _stopBrewService() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        Diagnostics.log('foreground service STOPPED');
      }
    } catch (e) {
      Diagnostics.log('foreground service stop FAILED: $e');
    }
  }

  /// Window-level keep-screen-on flag (FLAG_KEEP_SCREEN_ON on Android).
  /// Gated by the user's Settings → "Keep screen on while brewing" toggle.
  /// Best effort — swallows errors because the wake lock is a
  /// quality-of-life thing, not a correctness requirement.
  static Future<void> _enableWakeLock() async {
    if (!keepScreenOnDuringBrewNotifier.value) {
      Diagnostics.log('wake lock SKIPPED (setting disabled by user)');
      return;
    }
    try {
      await WakelockPlus.enable();
      Diagnostics.log('wake lock ENABLED');
    } catch (e) {
      Diagnostics.log('wake lock enable FAILED: $e');
    }
  }
  static Future<void> _disableWakeLock() async {
    try {
      await WakelockPlus.disable();
      Diagnostics.log('wake lock DISABLED');
    } catch (e) {
      Diagnostics.log('wake lock disable FAILED: $e');
    }
  }

  static ActiveBrewState? get current => activeBrewNotifier.value;

  /// Wire up the WidgetsBindingObserver that mirrors the main isolate's
  /// resumed/paused state into FlutterForegroundTask shared data. Called
  /// once at app startup, after the bindings are ready. The brew service
  /// reads this flag to decide whether to fire its own audio.
  static void installLifecycleSync() => _BrewLifecycleSync().install();

  /// Called by main.dart's foreground-task data callback when the
  /// foreground service has fired the brew-complete alert. Suppresses the
  /// in-app audio that handleExpiry would otherwise fire on resume,
  /// preventing double-ding.
  static void markExpiryHandledByService() {
    if (_expiryHandled) return;
    _expiryHandled = true;
    Diagnostics.log(
        'expiry pre-marked handled (foreground service already alerted)');
  }

  /// Called by any in-app expiry detector (TimerScreen ticker, home banner's
  /// periodic timer) when the brew's `endsAt` passes. Idempotent: fires the
  /// audio + haptic alert exactly once per brew.
  ///
  /// Coordinates with the OS-scheduled completion notification:
  ///   - Cancels it immediately. If it hasn't fired yet (foreground catch),
  ///     this prevents the OS sound and we play in-app audio instead.
  ///   - If it already fired (user was backgrounded/locked, came back),
  ///     the cancel just removes the shade entry. We suppress the in-app
  ///     audio in that case to avoid a second sound 1-2 minutes after the
  ///     OS one already alerted the user.
  static Future<void> handleExpiry() async {
    if (_expiryHandled) return;
    final state = current;
    if (state == null || !state.expired) return;

    // If the device is locked / app is paused, the OS-scheduled notification
    // is the user's primary alert. We do NOT cancel it from the background
    // (would prevent it from firing), and we do NOT try to play in-app
    // audio (Android mutes media-stream playback for paused apps). Leave
    // _expiryHandled unset so the next foreground tick can fire in-app
    // audio as a backup ding — useful on devices where the OS notif's
    // sound is suppressed.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != AppLifecycleState.resumed) {
      Diagnostics.log(
          'handleExpiry: app lifecycleState=$lifecycle — deferring '
          'to OS notification (not cancelling, not firing in-app)');
      return;
    }

    _expiryHandled = true;

    final delta = DateTime.now().difference(state.endsAt);
    Diagnostics.log(
        'handleExpiry fired (delta from endsAt: ${delta.inSeconds}s, foreground)');
    Alarm.cancelScheduledCompletion();
    Diagnostics.log('handleExpiry: invoking foregroundAlert');
    Alarm.foregroundAlert();

    // NOTE: wake lock is intentionally NOT released here. We keep the screen
    // alive through to explicit user resolution (Cancel / Done) so the user
    // doesn't have to race against the system screen-timeout to dismiss the
    // brew. Released in stop()/complete() instead.
  }

  /// Load any persisted brew from disk. Called once at app startup. If the
  /// persisted brew is more than an hour past its expiry, it's discarded as
  /// stale (assumes the user moved on). If the brew is still active (or
  /// recently expired but unacknowledged), re-acquires the wake lock so the
  /// app stays screen-on through to user resolution.
  static Future<void> load() async {
    final raw = await SecureStore.getString(_key);
    if (raw == null) return;
    try {
      final state =
          ActiveBrewState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final ageSinceExpiry =
          DateTime.now().difference(state.endsAt).inMinutes;
      if (ageSinceExpiry > 60) {
        await SecureStore.remove(_key);
        return;
      }
      activeBrewNotifier.value = state;
      if (!state.expired) await _enableWakeLock();
    } catch (_) {
      await SecureStore.remove(_key);
    }
  }

  static Future<void> _persist(ActiveBrewState? state) async {
    // Update the in-memory notifier FIRST and synchronously. Listeners
    // react off this, not off disk. If the disk write below throws, the
    // UI is still in a consistent state.
    activeBrewNotifier.value = state;
    if (state == null) {
      await SecureStore.remove(_key);
    } else {
      await SecureStore.setString(_key, jsonEncode(state.toJson()));
    }
  }

  /// Begin a brew. Any in-flight brew is stopped first.
  ///
  /// Acquires a window-level wake lock so the screen stays on through the
  /// brew — without it, the device auto-locking pauses Flutter's frame
  /// callbacks and the in-app expiry path never reaches the audio call.
  static Future<void> start({
    required Duration duration,
    required String appBarTitle,
    required String alarmTitle,
    required String alarmBody,
    String doneLabel = 'Done — log it',
    Drink? drinkToLog,
    double? volume,
    String notes = '',
  }) async {
    Diagnostics.log('brew START: "$appBarTitle" for ${duration.inSeconds}s');
    await stop();
    // Fresh brew — reset expiry guard. Reset ONLY here (not in stop() or
    // complete()) to close the race window where the home-banner Timer
    // could re-fire handleExpiry between flag clear and state clear.
    _expiryHandled = false;
    await _enableWakeLock();
    final endsAt = DateTime.now().add(duration);
    // Schedule the OS-side completion notification (best effort — on some
    // devices it's silenced anyway, hence the foreground service below).
    Alarm.scheduleCompletion(
      title: alarmTitle,
      body: alarmBody,
      when: endsAt,
    );
    // Start the foreground service so audio fires reliably even when the
    // device is locked.
    await _startBrewService(appBarTitle: appBarTitle, endsAt: endsAt);
    await _persist(ActiveBrewState(
      endsAt: endsAt,
      originalDuration: duration,
      appBarTitle: appBarTitle,
      alarmTitle: alarmTitle,
      alarmBody: alarmBody,
      doneLabel: doneLabel,
      drinkIdToLog: drinkToLog?.id,
      drinkTypeForLog: drinkToLog?.type,
      drinkDescriptionForLog: drinkToLog?.description,
      volume: volume,
      notes: notes,
    ));
  }

  /// Hard-cancel — used for explicit user "Cancel".
  static Future<void> stop() async {
    if (current == null) return;
    Diagnostics.log('brew STOP (user cancel)');
    // NOTE: do NOT reset _expiryHandled here. start() does that for the
    // next brew. Resetting here would let any in-flight Timer tick
    // re-fire handleExpiry between this line and the state clear below
    // — the very race that produced "double ding".
    Alarm.cancelScheduledCompletion();
    await _stopBrewService();
    await _persist(null);
    await _disableWakeLock();
  }

  /// Soft finish — used for "Done — log it" (or just "Done" for kettle).
  /// Logs the captured drink if [drinkIdToLog] is set, then clears state.
  static Future<void> complete() async {
    final state = current;
    if (state == null) return;
    Diagnostics.log(
        'brew COMPLETE (logged: ${state.drinkIdToLog != null}, '
        'desc: ${state.drinkDescriptionForLog ?? "—"})');
    // NOTE: same as stop() — do NOT reset the expiry flags here. start()
    // resets for the next brew. Resetting here was the source of the
    // ~80ms race that produced a second handleExpiry firing right after
    // the user tapped Done.

    // Write the log first — that's the user's data, most important to succeed.
    if (state.drinkIdToLog != null && state.volume != null) {
      try {
        String? type = state.drinkTypeForLog;
        String? description = state.drinkDescriptionForLog;
        if (type == null || description == null) {
          for (final d in drinksNotifier.value) {
            if (d.id == state.drinkIdToLog) {
              type ??= d.type;
              description ??= d.description;
              break;
            }
          }
        }
        final drink = Drink(
          id: state.drinkIdToLog!,
          type: type ?? '?',
          description: description ?? state.appBarTitle,
          volumePresets: [state.volume!],
          brewable: false,
          brewTimes: const [],
        );
        await LogStore.logDrink(
          drink: drink,
          volume: state.volume!,
          notes: state.notes,
        );
      } catch (_) {/* don't trap user in expired brew if log write fails */}
    }

    Alarm.cancelScheduledCompletion();
    await _stopBrewService();
    await _persist(null);
    await _disableWakeLock();
  }
}
