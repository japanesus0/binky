import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class DiagEntry {
  final DateTime time;
  final String message;
  const DiagEntry(this.time, this.message);

  /// Tab-separated single-line serialization for the on-disk log. ISO 8601
  /// for the timestamp so any DateTime parser can rehydrate it.
  String _toLine() => '${time.toIso8601String()}\t$message';

  /// Inverse of [_toLine]. Returns null on any malformed line so a partial
  /// write (power loss, force-stop mid-append) doesn't poison the whole
  /// session's reload.
  static DiagEntry? _tryParseLine(String line) {
    final tab = line.indexOf('\t');
    if (tab < 0) return null;
    final t = DateTime.tryParse(line.substring(0, tab));
    if (t == null) return null;
    return DiagEntry(t, line.substring(tab + 1));
  }
}

/// Diagnostic log with both an in-memory ring buffer (fast, listenable from
/// the UI) and a persistent file (survives process kills + reboots, so
/// crashes / forced exits / sudden background termination don't lose
/// context). View via Settings → "View diagnostics".
///
/// Persistence policy:
///   - File lives in the app's private support directory.
///   - Each [log] call appends one line synchronously (fast for small
///     writes; the alternative — async — would risk losing the line if
///     the process is killed before the future completes).
///   - File cap: ~500 entries. When exceeded, [init] rewrites the file
///     with only the most recent half on next launch.
///   - [clear] empties both the in-memory ring AND the on-disk file.
///   - On uninstall, Android wipes app-private storage automatically, so
///     no leakage.
class Diagnostics {
  static const _maxEntriesInMemory = 200;
  static const _maxEntriesOnDisk = 500;
  static const _logFileName = 'diagnostics.log';

  /// File handle for the on-disk log. Null if persistence couldn't be
  /// initialized (e.g. path_provider failed, disk full); in that case
  /// [log] still works in-memory.
  static File? _logFile;
  static bool _initialized = false;

  static final ValueNotifier<List<DiagEntry>> entries =
      ValueNotifier<List<DiagEntry>>(const []);

  /// Call once from `main()` BEFORE the first [log] call. Loads any prior-
  /// session entries from disk into the in-memory buffer so the UI shows
  /// recent history immediately, then truncates the file if it's grown
  /// past the cap. Best-effort: failures are silent — worst case, this
  /// session's logs only live in memory.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/$_logFileName');
      _logFile = f;

      if (await f.exists()) {
        final lines = await f.readAsLines();
        final loaded = <DiagEntry>[
          for (final line in lines)
            if (DiagEntry._tryParseLine(line) case final e?) e,
        ];

        // Rewrite the file if it's grown past the on-disk cap. We keep the
        // most-recent half; rewriting only when we hit the limit (rather
        // than every launch) keeps startup cheap.
        if (loaded.length > _maxEntriesOnDisk) {
          final kept = loaded.sublist(loaded.length - _maxEntriesOnDisk);
          await f.writeAsString(
            '${kept.map((e) => e._toLine()).join('\n')}\n',
            mode: FileMode.writeOnly,
          );
          loaded
            ..clear()
            ..addAll(kept);
        }

        // Populate the in-memory ring with the most recent slice.
        final start = (loaded.length > _maxEntriesInMemory)
            ? loaded.length - _maxEntriesInMemory
            : 0;
        entries.value = loaded.sublist(start);
      }
    } catch (e) {
      // Persistence failed; keep going with in-memory only.
      _logFile = null;
      if (kDebugMode) debugPrint('[Diag] init failed: $e');
    }

    // First entry of every session: a clear marker. Useful for finding
    // launches in the log, especially when investigating cases where the
    // app didn't fully start (Play Store intercept, crash mid-startup).
    log('=== app launched ===');
  }

  static void log(String message) {
    if (kDebugMode) debugPrint('[Diag] $message');
    final entry = DiagEntry(DateTime.now(), message);

    // In-memory ring buffer.
    final list = List<DiagEntry>.of(entries.value)..add(entry);
    if (list.length > _maxEntriesInMemory) {
      list.removeRange(0, list.length - _maxEntriesInMemory);
    }
    entries.value = list;

    // Append to the on-disk log. writeAsStringSync (rather than the async
    // writeAsString) so the line is on disk before this call returns —
    // important when investigating crashes / kills, where a pending async
    // write would be lost.
    final f = _logFile;
    if (f != null) {
      try {
        f.writeAsStringSync(
          '${entry._toLine()}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {/* best effort */}
    }
  }

  /// Empty both in-memory and on-disk logs. Used by the Clear button in
  /// the Diagnostics UI.
  static Future<void> clear() async {
    entries.value = const [];
    final f = _logFile;
    if (f != null) {
      try {
        await f.writeAsString('', mode: FileMode.writeOnly);
      } catch (_) {/* best effort */}
    }
  }

  static String dumpAsText() {
    final out = StringBuffer();
    for (final e in entries.value) {
      out.writeln('${_fmtTime(e.time)}  ${e.message}');
    }
    return out.toString();
  }
}

String _fmtTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  String three(int n) => n.toString().padLeft(3, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
}

class _ClearLogButton extends StatelessWidget {
  const _ClearLogButton();
  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: 'Clear log',
      onPressed: () => Diagnostics.clear(),
    );
  }
}

class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all_outlined),
            tooltip: 'Copy entire log',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(
                ClipboardData(text: Diagnostics.dumpAsText()),
              );
              messenger.clearSnackBars();
              messenger.showSnackBar(
                const SnackBar(content: Text('Log copied to clipboard.')),
              );
            },
          ),
          const _ClearLogButton(),
        ],
      ),
      body: ValueListenableBuilder<List<DiagEntry>>(
        valueListenable: Diagnostics.entries,
        builder: (context, items, _) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No diagnostic events yet. Run through a brew or tap the '
                  'test button below.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: items.length,
            // Newest first.
            reverse: true,
            itemBuilder: (context, i) {
              final e = items[i];
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fmtTime(e.time),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFF888888),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        e.message,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
