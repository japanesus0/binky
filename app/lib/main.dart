import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'active_brew.dart';
import 'diagnostics.dart';
import 'drinks_editor.dart';
import 'history.dart';
import 'screens.dart';
import 'settings.dart';
import 'splash_screen.dart';
import 'storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the persistent diagnostic log FIRST so every subsequent
  // event in this startup sequence — plugin init, storage migration,
  // ActiveBrew rehydration — gets captured. If the app crashes mid-
  // startup, the file is what tells us how far we got. Must come after
  // ensureInitialized() (path_provider needs the binding) but before
  // anything else.
  await Diagnostics.init();

  // Init the foreground-task plugin. Done before anything else so the
  // service can be started from ActiveBrew on first brew without any
  // additional setup. The persistent-notification channel is configured
  // here too — low importance so it doesn't ding when the service starts.
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'brew_in_progress_v1',
      channelName: 'Brew in progress',
      channelDescription:
          'Persistent while a brew or kettle timer is running, so the '
          'app can ring at expiry even if the screen is locked.',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(1000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );

  // Listen for the "brew_expired" message from the foreground service
  // isolate. When the service fires the audio (while the user is locked
  // or the app is backgrounded), it sends this so the main isolate can
  // mark the brew as already-alerted — preventing a second in-app ding
  // when the user later returns to the app.
  FlutterForegroundTask.addTaskDataCallback(_onForegroundTaskData);

  // Mirror our lifecycle (resumed vs paused/inactive/detached) into the
  // shared data the service isolate reads. When the app is RESUMED at
  // expiry, the main isolate fires the in-app ding via handleExpiry; the
  // service sees the resumed flag and skips its own audio so the user
  // doesn't hear two dings.
  ActiveBrew.installLifecycleSync();

  // First-ever step on each cold start: move any pre-encryption plaintext
  // data into the encrypted store. Idempotent — second-and-later launches
  // see the migration flag and no-op immediately. Must run BEFORE any
  // store load so the subsequent reads pull from the encrypted location.
  await SecureStore.migrateFromSharedPreferences();

  // Lightweight, sync-ish startup.
  await Settings.load();
  await DrinksStore.load();
  await ActiveBrew.load();

  runApp(const BinkyApp());
}

void _onForegroundTaskData(Object data) {
  if (data == 'brew_expired') {
    Diagnostics.log('main: received brew_expired from foreground service');
    ActiveBrew.markExpiryHandledByService();
  } else if (data == 'brew_expired_main_will_alert') {
    // Service noticed expiry but deferred audio because main is resumed
    // and will fire the in-app ding itself. Purely informational — no
    // state change needed; main's banner / TimerScreen tick will fire
    // handleExpiry within ~1s.
    Diagnostics.log(
        'main: service deferred audio (app resumed — main will alert)');
  }
}

class BinkyApp extends StatelessWidget {
  const BinkyApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF6B4423);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'binky',
          themeMode: mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: seed),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seed,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: const SplashScreen(next: HomeScreen()),
        );
      },
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _quickLogCategory(
      BuildContext context, DrinkCategory cat) async {
    final messenger = ScaffoldMessenger.of(context);
    final defaultDrink = DrinksStore.defaultFor(cat.name);
    if (defaultDrink == null) {
      Diagnostics.log(
          'quick-log skipped: no default for category "${cat.name}"');
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
              'No ${cat.name} sub-types yet. Tap to open the category.'),
        ),
      );
      return;
    }
    final vol = defaultDrink.defaultVolume;
    final entry = await LogStore.logDrink(
      drink: defaultDrink,
      volume: vol,
    );
    Diagnostics.log(
        'quick-log (Home long-press): ${defaultDrink.description} '
        '${vol.toStringAsFixed(0)} oz');
    messenger.clearSnackBars();
    // Workaround for Flutter issue #137163: SnackBars with an action
    // sometimes ignore `duration:` and stay forever — the framework's
    // internal dismiss timer doesn't fire reliably. Schedule our own
    // delayed close on the returned controller as a backup so the
    // SnackBar always dismisses when we said it should.
    const dismissAfter = Duration(seconds: 3);
    final ctrl = messenger.showSnackBar(
      SnackBar(
        duration: dismissAfter,
        content: Text('Logged ${defaultDrink.description} '
            '(${vol.toStringAsFixed(0)} oz)'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            Diagnostics.log(
                'quick-log UNDONE: ${defaultDrink.description}');
            LogStore.delete(entry.id);
          },
        ),
      ),
    );
    Future<void>.delayed(dismissAfter, () {
      try { ctrl.close(); } catch (_) {}
    }).ignore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Branded but discrete — serif typeface for visual continuity
        // with the splash wordmark and the launcher `b` glyph, but no
        // bold weight or letter spacing so the AppBar reads quietly
        // rather than asserting the brand at every screen entry.
        //
        // Transparent surface (no background tint, no elevation, no
        // scroll-under tint) so the bar reads as the page itself
        // rather than as a distinct "logo banner" tile. The wordmark
        // and action icons inherit theme foreground colors, so dark
        // mode is handled automatically.
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        title: const Text(
          'binky',
          style: TextStyle(fontFamily: 'serif'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: 'Summary',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SummaryScreen()),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'history':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  );
                case 'drinks':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DrinksEditorScreen(),
                    ),
                  );
                case 'settings':
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'history', child: Text('History')),
              PopupMenuItem(value: 'drinks', child: Text('Edit drinks')),
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const _ActiveBrewBanner(),
          Expanded(
            // Rebuild when drinks change so the default-sub-type subtitle
            // stays in sync after Edit Drinks tweaks.
            child: ValueListenableBuilder<List<Drink>>(
              valueListenable: drinksNotifier,
              builder: (context, drinks, _) {
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: drinkCategories.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final cat = drinkCategories[i];
                    final defaultDrink = DrinksStore.defaultFor(cat.name);
                    return ListTile(
                      leading: CircleAvatar(child: Icon(cat.icon)),
                      title: Text(cat.name),
                      subtitle: Text(defaultDrink == null
                          ? 'No sub-types — tap to add'
                          : 'Default: ${defaultDrink.description} · '
                              '${defaultDrink.defaultVolume.toStringAsFixed(0)} oz'),
                      trailing:
                          cat.brewable ? const Icon(Icons.timer_outlined) : null,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CategoryScreen(category: cat),
                        ),
                      ),
                      onLongPress: () => _quickLogCategory(context, cat),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Sticky strip at the top of Home that appears whenever a brew is running
/// (or has just completed). Tap to return to the TimerScreen.
class _ActiveBrewBanner extends StatelessWidget {
  const _ActiveBrewBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActiveBrewState?>(
      valueListenable: activeBrewNotifier,
      builder: (context, brew, _) {
        if (brew == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Material(
          color: cs.primaryContainer,
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TimerScreen()),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.timer, color: cs.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(child: _LiveBrewSummary(brew: brew)),
                  Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LiveBrewSummary extends StatefulWidget {
  final ActiveBrewState brew;
  const _LiveBrewSummary({required this.brew});

  @override
  State<_LiveBrewSummary> createState() => _LiveBrewSummaryState();
}

class _LiveBrewSummaryState extends State<_LiveBrewSummary> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (!mounted) return;
        setState(() {});
        // When the user has the home screen open (not the TimerScreen),
        // this is the only path that runs at brew expiry. Without this
        // call, the OS-ongoing chronometer ticks into negative numbers
        // and no completion notification ever fires on devices where the
        // scheduled OS alarm is gated/delayed.
        ActiveBrew.handleExpiry();
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.brew.remaining;
    final cs = Theme.of(context).colorScheme;
    final isDone = r.isNegative || r.inMilliseconds <= 0;
    final mm = r.inMinutes.remainder(60).abs().toString().padLeft(2, '0');
    final ss = r.inSeconds.remainder(60).abs().toString().padLeft(2, '0');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.brew.appBarTitle,
          style: TextStyle(
              color: cs.onPrimaryContainer, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          isDone ? 'Ready — tap to finish' : '$mm:$ss remaining',
          style: TextStyle(color: cs.onPrimaryContainer),
        ),
      ],
    );
  }
}
