import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'active_brew.dart';
import 'settings.dart';
import 'storage.dart';

// =============================================================================
// Category — sub-type picker for one of the 5 top-level categories.
// =============================================================================

class CategoryScreen extends StatelessWidget {
  final DrinkCategory category;
  const CategoryScreen({super.key, required this.category});

  Future<void> _openOtherDialog(BuildContext context) async {
    final drink = await showDialog<Drink>(
      context: context,
      builder: (_) => _OtherDrinkDialog(category: category),
    );
    if (drink == null) return;
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DrinkScreen(drink: drink)),
    );
  }

  Future<void> _quickLog(BuildContext context, Drink d) async {
    final messenger = ScaffoldMessenger.of(context);
    final entry = await LogStore.logDrink(
      drink: d,
      volume: d.defaultVolume,
    );
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Logged ${d.description} '
            '(${d.defaultVolume.toStringAsFixed(0)} oz)'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => LogStore.delete(entry.id),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(category.name)),
      body: ValueListenableBuilder<List<Drink>>(
        valueListenable: drinksNotifier,
        builder: (context, _, __) {
          final inCategory = DrinksStore.byCategory(category.name);
          return ListView(
            children: [
              for (final d in inCategory)
                ListTile(
                  leading: d.isDefault
                      ? const Icon(Icons.star, color: Colors.amber)
                      : const Icon(Icons.star_border, color: Colors.transparent),
                  title: Text(d.description),
                  subtitle: Text(
                    '${d.defaultVolume.toStringAsFixed(0)} oz'
                    '${d.brewable && d.brewTimes.isNotEmpty ? ' · brew ${d.brewTimes.join("/")} min' : ''}',
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => DrinkScreen(drink: d)),
                  ),
                  onLongPress: () => _quickLog(context, d),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Other...'),
                subtitle: Text('Custom ${category.name}'),
                onTap: () => _openOtherDialog(context),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Dialog shown when the user picks "Other..." in a category. Captures a
/// description and lets them decide whether to persist it for next time
/// (added to that category's drink list) or treat it as a one-off log entry
/// (synthetic Drink, never saved to storage).
class _OtherDrinkDialog extends StatefulWidget {
  final DrinkCategory category;
  const _OtherDrinkDialog({required this.category});

  @override
  State<_OtherDrinkDialog> createState() => _OtherDrinkDialogState();
}

class _OtherDrinkDialogState extends State<_OtherDrinkDialog> {
  final _name = TextEditingController();
  bool _save = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;

    final cat = widget.category;
    final Drink drink;
    if (_save) {
      drink = Drink(
        id: DrinksStore.nextId(),
        type: cat.name,
        description: name,
        volumePresets: List<double>.of(cat.volumePresets),
        brewable: cat.brewable,
        brewTimes: List<int>.of(cat.defaultBrewTimes),
      );
      await DrinksStore.upsert(drink);
    } else {
      // Synthetic, never-persisted drink. Negative id so it can't collide
      // with anything in the drinks store. LogEntry denormalizes type +
      // description, so logging this works fine despite the id being a
      // dead pointer.
      drink = Drink(
        id: -DateTime.now().microsecondsSinceEpoch.remainder(0x7fffffff),
        type: cat.name,
        description: name,
        volumePresets: List<double>.of(cat.volumePresets),
        brewable: cat.brewable,
        brewTimes: List<int>.of(cat.defaultBrewTimes),
      );
    }
    if (!mounted) return;
    Navigator.pop(context, drink);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New ${widget.category.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'e.g. Chai',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _continue(),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _save,
            onChanged: (v) => setState(() => _save = v ?? false),
            title: const Text('Save for next time'),
            subtitle: Text('Adds it to ${widget.category.name}'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _continue,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

// =============================================================================
// Drink detail
// =============================================================================

class DrinkScreen extends StatefulWidget {
  final Drink drink;
  const DrinkScreen({super.key, required this.drink});

  @override
  State<DrinkScreen> createState() => _DrinkScreenState();
}

class _DrinkScreenState extends State<DrinkScreen> {
  late final TextEditingController _notes;
  double? _selectedVolume;
  bool _customVolume = false;
  int? _selectedBrew;
  bool _customBrew = false;

  @override
  void initState() {
    super.initState();
    _notes = TextEditingController();
    // Volume: pre-select the first preset (the user's chosen default).
    // If somehow the drink has no presets, leave null and force a Custom
    // pick via the chip.
    final positiveVols =
        widget.drink.volumePresets.where((v) => v > 0).toList();
    if (positiveVols.isNotEmpty) {
      _selectedVolume = positiveVols.first;
    }
    // Brew time: same idea — pre-select the first positive preset.
    final positiveBrews = widget.drink.brewTimes.where((t) => t > 0).toList();
    if (widget.drink.brewable && positiveBrews.isNotEmpty) {
      _selectedBrew = positiveBrews.first;
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _logDrink() async {
    final vol = _selectedVolume ?? widget.drink.defaultVolume;
    await LogStore.logDrink(
      drink: widget.drink,
      volume: vol,
      notes: _notes.text,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(content: Text('Logged ${widget.drink.description}')),
    );
    Navigator.pop(context);
  }

  Future<void> _pickCustomVolume() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) =>
          _CustomVolumeDialog(initial: _selectedVolume?.round() ?? 16),
    );
    if (picked != null && picked > 0) {
      setState(() {
        _selectedVolume = picked.toDouble();
        _customVolume = true;
      });
    }
  }

  Future<void> _pickCustomBrew() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => _CustomBrewDialog(initial: _selectedBrew ?? 5),
    );
    if (picked != null && picked > 0) {
      setState(() {
        _selectedBrew = picked;
        _customBrew = true;
      });
    }
  }

  /// Returns false if the user backed out of replacing a running brew.
  Future<bool> _confirmReplaceIfRunning() async {
    final existing = ActiveBrew.current;
    if (existing == null) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('A brew is already running'),
        content: Text(
          '"${existing.appBarTitle}" is in progress. Starting a new one will '
          'cancel it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _startBrew(Drink d) async {
    if (!await _confirmReplaceIfRunning()) return;
    if (!mounted) return;
    final vol = _selectedVolume ?? d.defaultVolume;
    await ActiveBrew.start(
      duration: Duration(minutes: _selectedBrew!),
      appBarTitle: 'Brewing ${d.description}',
      alarmTitle: 'Brew complete',
      alarmBody: '${d.description} is ready.',
      drinkToLog: d,
      volume: vol,
      notes: _notes.text,
    );
    if (!mounted) return;
    // Replace DrinkScreen on the stack so backing out of TimerScreen lands
    // on Home, not back here.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const TimerScreen()),
    );
  }

  Future<void> _startKettle(Drink d) async {
    if (!await _confirmReplaceIfRunning()) return;
    if (!mounted) return;
    // Capture messenger before awaits so we can SnackBar after returning.
    final messenger = ScaffoldMessenger.of(context);
    final minutes = kettleMinutesNotifier.value;
    await ActiveBrew.start(
      duration: Duration(minutes: minutes),
      appBarTitle: 'Kettle for ${d.description}',
      alarmTitle: 'Kettle ready',
      alarmBody: 'Water is hot — time to brew ${d.description}.',
      doneLabel: 'Brew now',
      // No drinkToLog — kettle is just a prep timer.
    );
    if (!mounted) return;
    // push (not pushReplacement) so tapping "Brew now" pops us back HERE on
    // DrinkScreen, where the Brew button is waiting one tap away.
    final completed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const TimerScreen()),
    );
    if (completed == true) {
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
            content: Text("Water's hot — ready to brew ${d.description}.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.drink;
    final brewPresets = d.brewTimes.where((t) => t > 0).toList();
    final volPresets = d.volumePresets.where((v) => v > 0).toList();
    final showBrew = d.brewable;

    return Scaffold(
      appBar: AppBar(title: Text(d.description)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(d.type, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 16),
            Text('Volume', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final v in volPresets)
                  ChoiceChip(
                    label: Text('${v.toStringAsFixed(0)} oz'),
                    selected: !_customVolume && _selectedVolume == v,
                    onSelected: (_) => setState(() {
                      _selectedVolume = v;
                      _customVolume = false;
                    }),
                  ),
                ChoiceChip(
                  label: Text(_customVolume && _selectedVolume != null
                      ? 'Custom: ${_selectedVolume!.toStringAsFixed(0)} oz'
                      : 'Custom…'),
                  selected: _customVolume,
                  onSelected: (_) => _pickCustomVolume(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (showBrew) ...[
              Text('Brew time',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in brewPresets)
                    ChoiceChip(
                      label: Text('$t min'),
                      selected: !_customBrew && _selectedBrew == t,
                      onSelected: (_) => setState(() {
                        _selectedBrew = t;
                        _customBrew = false;
                      }),
                    ),
                  ChoiceChip(
                    label: Text(_customBrew && _selectedBrew != null
                        ? 'Custom: $_selectedBrew min'
                        : 'Custom…'),
                    selected: _customBrew,
                    onSelected: (_) => _pickCustomBrew(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 24),
            if (showBrew && _selectedBrew != null && _selectedBrew! > 0)
              FilledButton.icon(
                icon: const Icon(Icons.timer),
                label: Text('Brew $_selectedBrew min, then log'),
                onPressed: () => _startBrew(d),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.check),
              label: const Text('Log without brewing'),
              onPressed: _logDrink,
            ),
            if (showBrew) ...[
              const SizedBox(height: 8),
              ValueListenableBuilder<int>(
                valueListenable: kettleMinutesNotifier,
                builder: (context, minutes, _) {
                  return OutlinedButton.icon(
                    icon: const Icon(Icons.local_fire_department_outlined),
                    label: Text('Kettle Time ($minutes min)'),
                    onPressed: () => _startKettle(d),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CustomVolumeDialog extends StatefulWidget {
  final int initial;
  const _CustomVolumeDialog({required this.initial});

  @override
  State<_CustomVolumeDialog> createState() => _CustomVolumeDialogState();
}

class _CustomVolumeDialogState extends State<_CustomVolumeDialog> {
  late double _ounces;

  @override
  void initState() {
    super.initState();
    _ounces = widget.initial.clamp(1, 64).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final v = _ounces.round();
    return AlertDialog(
      title: const Text('Custom volume'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$v oz',
              style: Theme.of(context).textTheme.headlineMedium),
          Slider(
            value: _ounces,
            min: 1,
            max: 64,
            divisions: 63,
            label: '$v oz',
            onChanged: (val) => setState(() => _ounces = val),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, v),
          child: const Text('Use'),
        ),
      ],
    );
  }
}

class _CustomBrewDialog extends StatefulWidget {
  final int initial;
  const _CustomBrewDialog({required this.initial});

  @override
  State<_CustomBrewDialog> createState() => _CustomBrewDialogState();
}

class _CustomBrewDialogState extends State<_CustomBrewDialog> {
  late double _minutes;

  @override
  void initState() {
    super.initState();
    _minutes = widget.initial.clamp(1, 60).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final m = _minutes.round();
    return AlertDialog(
      title: const Text('Custom brew time'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$m min',
              style: Theme.of(context).textTheme.headlineMedium),
          Slider(
            value: _minutes,
            min: 1,
            max: 60,
            divisions: 59,
            label: '$m min',
            onChanged: (v) => setState(() => _minutes = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, m),
          child: const Text('Use'),
        ),
      ],
    );
  }
}

// =============================================================================
// Timer (reads from ActiveBrew — does NOT own state)
// =============================================================================

class TimerScreen extends StatefulWidget {
  const TimerScreen({super.key});

  @override
  State<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    final brew = ActiveBrew.current;
    if (brew == null) {
      // No active brew — pop after frame. Shouldn't happen via UI flow.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      _remaining = Duration.zero;
      _ticker = createTicker((_) {});
      return;
    }
    _remaining = brew.remaining;
    if (brew.expired) {
      // Already done by the time we arrived. The ActiveBrew._expiryHandled
      // guard inside handleExpiry decides whether sound/haptics fire again.
      _remaining = Duration.zero;
    }

    _ticker = createTicker((_) {
      final b = ActiveBrew.current;
      if (b == null) {
        _ticker.stop();
        if (mounted) Navigator.pop(context);
        return;
      }
      final left = b.remaining;
      if (left.isNegative || left.inMilliseconds <= 0) {
        _ticker.stop();
        // handleExpiry is idempotent and fires sound + haptics + tries to
        // post the OS notification. _LiveBrewSummary's home banner timer
        // calls the same method — the flag inside ActiveBrew ensures
        // exactly-once side effects per brew.
        ActiveBrew.handleExpiry();
        if (mounted) setState(() => _remaining = Duration.zero);
      } else {
        if (mounted) setState(() => _remaining = left);
      }
    });
    _ticker.start();
  }

  @override
  void dispose() {
    if (_ticker.isActive) _ticker.stop();
    _ticker.dispose();
    // NOTE: we deliberately do NOT touch ActiveBrew here. Backing out of
    // this screen leaves the brew running in the background — the user
    // can return to it via the notification tap or the home banner.
    super.dispose();
  }

  Future<void> _onCancel() async {
    // Pop FIRST so the screen comes off the navigator before the cleanup
    // runs. Previously we awaited stop() before popping; if stop() hung
    // or ran slowly, the ValueListenableBuilder rebuilt TimerScreen with
    // a null brew (rendering an empty Scaffold) while still mounted —
    // producing the "black screen, must relaunch" symptom.
    if (mounted) Navigator.pop(context);
    unawaited(ActiveBrew.stop());
  }

  Future<void> _onDone() async {
    // Same pop-first pattern as _onCancel. complete() writes the log + the
    // log write is durable via SecureStore, so the user navigating away
    // before it finishes doesn't lose data.
    // Pops with true — kettle flow uses this to show the "water's hot" nudge.
    if (mounted) Navigator.pop(context, true);
    unawaited(ActiveBrew.complete());
  }

  String _fmt(Duration d) {
    final ms = d.inMilliseconds < 0 ? Duration.zero : d;
    final m = ms.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = ms.inSeconds.remainder(60).toString().padLeft(2, '0');
    final mls =
        ms.inMilliseconds.remainder(1000).toString().padLeft(3, '0');
    return '$m:$s.$mls';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ActiveBrewState?>(
      valueListenable: activeBrewNotifier,
      builder: (context, brew, _) {
        if (brew == null) {
          // Drained mid-build — render an empty scaffold while the post-frame
          // pop runs.
          return const Scaffold(body: SizedBox.shrink());
        }
        final totalMs = brew.originalDuration.inMilliseconds;
        final progress = totalMs == 0
            ? 1.0
            : 1 - (_remaining.inMilliseconds / totalMs);
        final isDone = brew.expired;

        return Scaffold(
          appBar: AppBar(title: Text(brew.appBarTitle)),
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 240,
                  height: 240,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 240,
                        height: 240,
                        child: CircularProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          strokeWidth: 12,
                        ),
                      ),
                      Text(
                        _fmt(_remaining),
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                if (!isDone)
                  OutlinedButton(
                    onPressed: _onCancel,
                    child: const Text('Cancel'),
                  )
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text(brew.doneLabel),
                    onPressed: _onDone,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// Summary
// =============================================================================

class SummaryScreen extends StatefulWidget {
  const SummaryScreen({super.key});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  late Future<List<LogEntry>> _future;
  late DateTime _weekStart; // Sunday at 00:00 local time

  @override
  void initState() {
    super.initState();
    _future = LogStore.load();
    _weekStart = _startOfWeek(DateTime.now());
  }

  /// Returns the Sunday at 00:00 of the week containing [d].
  /// Dart's [DateTime.weekday] is Mon=1..Sun=7; `% 7` makes Sun=0..Sat=6.
  static DateTime _startOfWeek(DateTime d) {
    final dayStart = DateTime(d.year, d.month, d.day);
    final daysSinceSunday = dayStart.weekday % 7;
    return dayStart.subtract(Duration(days: daysSinceSunday));
  }

  bool get _canGoForward {
    final next = _weekStart.add(const Duration(days: 7));
    return !next.isAfter(_startOfWeek(DateTime.now()));
  }

  void _prevWeek() {
    setState(() => _weekStart =
        _weekStart.subtract(const Duration(days: 7)));
  }

  void _nextWeek() {
    if (!_canGoForward) return;
    setState(() => _weekStart = _weekStart.add(const Duration(days: 7)));
  }

  void _jumpToToday() {
    setState(() => _weekStart = _startOfWeek(DateTime.now()));
  }

  Future<void> _pickWeek() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _weekStart.add(const Duration(days: 3)),
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
      helpText: 'Pick any day in the target week',
    );
    if (picked != null) {
      setState(() => _weekStart = _startOfWeek(picked));
    }
  }

  String _dateKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.today),
            tooltip: 'This week',
            onPressed: _jumpToToday,
          ),
        ],
      ),
      body: FutureBuilder<List<LogEntry>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final allEntries = snap.data!;
          final weekEnd = _weekStart.add(const Duration(days: 7));

          // Filter to entries within [weekStart, weekEnd).
          final entries = allEntries.where((e) {
            final ts = e.timestamp;
            return !ts.isBefore(_weekStart) && ts.isBefore(weekEnd);
          }).toList();

          // 7 bars, one per day, anchored on Sunday of the selected week.
          final weekTotals = List<double>.filled(7, 0);
          for (final e in entries) {
            final dayStart = DateTime(
                e.timestamp.year, e.timestamp.month, e.timestamp.day);
            final i = dayStart.difference(_weekStart).inDays;
            if (i >= 0 && i < 7) weekTotals[i] += e.volume;
          }

          // Daily breakdown — only for days within this week that have logs.
          final byDate = <String, Map<String, double>>{};
          for (final e in entries) {
            final d = _dateKey(e.timestamp);
            byDate.putIfAbsent(d, () => <String, double>{});
            byDate[d]!.update(e.type, (v) => v + e.volume,
                ifAbsent: () => e.volume);
          }
          final sortedDates = byDate.keys.toList()
            ..sort((a, b) => b.compareTo(a));

          return ListView(
            children: [
              _WeekNavigator(
                weekStart: _weekStart,
                canGoForward: _canGoForward,
                onPrev: _prevWeek,
                onNext: _nextWeek,
                onTapLabel: _pickWeek,
              ),
              _WeeklyChart(totals: weekTotals, weekStart: _weekStart),
              const SizedBox(height: 4),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: Text('Nothing logged this week.')),
                )
              else
                ...sortedDates.map((date) {
                  final totals = byDate[date]!;
                  final dayTotal =
                      totals.values.fold<double>(0, (s, v) => s + v);
                  return Card(
                    margin: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(date,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          ...totals.entries.map((e) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(e.key),
                                    Text('${e.value.toStringAsFixed(0)} oz'),
                                  ],
                                ),
                              )),
                          const Divider(),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Total',
                                  style:
                                      TextStyle(fontWeight: FontWeight.bold)),
                              Text('${dayTotal.toStringAsFixed(0)} oz',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

class _WeekNavigator extends StatelessWidget {
  final DateTime weekStart;
  final bool canGoForward;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onTapLabel;

  const _WeekNavigator({
    required this.weekStart,
    required this.canGoForward,
    required this.onPrev,
    required this.onNext,
    required this.onTapLabel,
  });

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _label() {
    final end = weekStart.add(const Duration(days: 6));
    final startStr = '${_months[weekStart.month - 1]} ${weekStart.day}';
    final endStr = (weekStart.month == end.month)
        ? '${end.day}'
        : '${_months[end.month - 1]} ${end.day}';
    final thisYear = DateTime.now().year;
    final yearStr =
        (weekStart.year == thisYear && end.year == thisYear)
            ? ''
            : ', ${end.year}';
    return '$startStr – $endStr$yearStr';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous week',
            onPressed: onPrev,
          ),
          Expanded(
            child: Center(
              child: TextButton.icon(
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(_label()),
                onPressed: onTapLabel,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: canGoForward ? 'Next week' : 'No future weeks',
            onPressed: canGoForward ? onNext : null,
          ),
        ],
      ),
    );
  }
}

class _WeeklyChart extends StatelessWidget {
  final List<double> totals; // 7 entries, weekStart..weekStart+6
  final DateTime weekStart;

  const _WeeklyChart({required this.totals, required this.weekStart});

  static const _dayLabels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  @override
  Widget build(BuildContext context) {
    final maxV = totals
        .fold<double>(0, (m, v) => v > m ? v : m)
        .clamp(1, double.infinity);
    final cs = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Daily volume',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SizedBox(
              height: 140,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(7, (i) {
                  final day = weekStart.add(Duration(days: i));
                  final ratio = (totals[i] / maxV).clamp(0.0, 1.0);
                  final label = _dayLabels[day.weekday % 7];
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Column(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: totals[i] == 0 ? 0.02 : ratio,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: totals[i] == 0
                                        ? cs.surfaceContainerHighest
                                        : cs.primary,
                                    borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(6)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            totals[i] == 0
                                ? '—'
                                : totals[i].toStringAsFixed(0),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          Text(label,
                              style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
