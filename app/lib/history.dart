import 'package:flutter/material.dart';
import 'export.dart';
import 'storage.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<LogEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<LogEntry>> _load() async {
    final all = await LogStore.load();
    all.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return all;
  }

  void _reload() {
    setState(() => _future = _load());
  }

  String _fmtDateTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _editEntry(LogEntry entry) async {
    final updated = await showDialog<LogEntry>(
      context: context,
      builder: (ctx) => _EditEntryDialog(entry: entry),
    );
    if (updated != null) {
      await LogStore.update(updated);
      _reload();
    }
  }

  Future<void> _deleteEntry(LogEntry entry) async {
    await LogStore.delete(entry.id);
    _reload();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text('Deleted ${entry.description}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await LogStore.insert(entry);
            _reload();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export CSV',
            onPressed: () async {
              // Capture the messenger up front so we don't reference
              // BuildContext across the await — keeps the analyzer happy.
              final messenger = ScaffoldMessenger.of(context);
              try {
                await LogExporter.shareCsv();
              } catch (e) {
                messenger.clearSnackBars();
                messenger.showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 3),
                    content: Text('Export failed: $e'),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: FutureBuilder<List<LogEntry>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snap.data!;
          if (entries.isEmpty) {
            return const Center(child: Text('Nothing logged yet.'));
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
              return Dismissible(
                key: ValueKey(e.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Icon(
                    Icons.delete,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                onDismissed: (_) => _deleteEntry(e),
                child: ListTile(
                  leading: CircleAvatar(child: Text(e.type[0])),
                  title: Text(e.description),
                  subtitle: Text(
                    '${_fmtDateTime(e.timestamp)} · '
                    '${e.volume.toStringAsFixed(0)} oz'
                    '${e.notes.isEmpty ? '' : ' · ${e.notes}'}',
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _editEntry(e),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _EditEntryDialog extends StatefulWidget {
  final LogEntry entry;
  const _EditEntryDialog({required this.entry});

  @override
  State<_EditEntryDialog> createState() => _EditEntryDialogState();
}

class _EditEntryDialogState extends State<_EditEntryDialog> {
  late final TextEditingController _volume;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    _volume =
        TextEditingController(text: widget.entry.volume.toStringAsFixed(0));
    _notes = TextEditingController(text: widget.entry.notes);
  }

  @override
  void dispose() {
    _volume.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.entry.description}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _volume,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Volume (oz)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(
              labelText: 'Notes',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final vol = double.tryParse(_volume.text) ?? widget.entry.volume;
            Navigator.pop(
              context,
              widget.entry.copyWith(volume: vol, notes: _notes.text),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
