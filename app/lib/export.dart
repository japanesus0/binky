import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'storage.dart';

class LogExporter {
  /// Renders all log entries as CSV and opens the platform share sheet so
  /// the user can save / email / send the file elsewhere.
  static Future<void> shareCsv() async {
    final entries = await LogStore.load()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final csv = _toCsv(entries);

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${dir.path}/binky-log-$stamp.csv');
    await file.writeAsString(csv);

    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv', name: 'binky-log-$stamp.csv')],
      subject: 'binky log export',
    );
  }

  static String _toCsv(List<LogEntry> entries) {
    final b = StringBuffer()
      ..writeln('timestamp,drink_id,type,description,volume_oz,notes');
    for (final e in entries) {
      b.writeln([
        e.timestamp.toIso8601String(),
        e.drinkId,
        _csvField(e.type),
        _csvField(e.description),
        e.volume,
        _csvField(e.notes),
      ].join(','));
    }
    return b.toString();
  }

  /// Quote a CSV field if it contains characters that need escaping.
  static String _csvField(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }
}
