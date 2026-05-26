import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DiagEntry {
  final DateTime time;
  final String message;
  const DiagEntry(this.time, this.message);
}

/// Lightweight in-memory diagnostic log. The whole point: when audio /
/// notifications misbehave, we want a record of what fired and what didn't
/// without needing adb logcat. View via Settings → "View diagnostics".
///
/// Capped at 200 entries; oldest entries roll off. Never persisted to disk
/// (would be misleading across launches and would leak through the
/// encrypted-store boundary).
class Diagnostics {
  static const _maxEntries = 200;
  static final ValueNotifier<List<DiagEntry>> entries =
      ValueNotifier<List<DiagEntry>>(const []);

  static void log(String message) {
    if (kDebugMode) debugPrint('[Diag] $message');
    final list = List<DiagEntry>.of(entries.value)
      ..add(DiagEntry(DateTime.now(), message));
    if (list.length > _maxEntries) {
      list.removeRange(0, list.length - _maxEntries);
    }
    entries.value = list;
  }

  static void clear() {
    entries.value = const [];
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
    return const IconButton(
      icon: Icon(Icons.delete_outline),
      tooltip: 'Clear log',
      onPressed: Diagnostics.clear,
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
