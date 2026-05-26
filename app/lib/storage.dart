import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// =============================================================================
// SecureStore — thin layer over FlutterSecureStorage with a SharedPreferences-
// shaped API. AES-256 GCM via Android Keystore + EncryptedSharedPreferences.
//
// All app persistence (drinks, log, settings, active brew) goes through this.
// The one-shot migration on first launch after the v1.0.0 upgrade carries
// any pre-encryption plaintext data over into the encrypted store.
// =============================================================================

class SecureStore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const _migrationFlag = '_migrated_to_secure_v1';

  static Future<String?> getString(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setString(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (_) {/* best effort */}
  }

  static Future<void> remove(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {/* best effort */}
  }

  /// One-shot copy of any pre-encryption shared_preferences data into secure
  /// storage. Run from main() before any other store load. After every key
  /// has been moved, sets a flag so subsequent launches no-op immediately.
  ///
  /// Drops shared_preferences entries after copying so the plaintext XML
  /// stops carrying user data.
  static Future<void> migrateFromSharedPreferences() async {
    try {
      if (await _storage.read(key: _migrationFlag) == 'done') return;
    } catch (_) {
      // Keystore unavailable — nothing safe to do; bail without migrating.
      return;
    }

    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }

    // Plain-string keys
    for (final key in const ['drinks_v2', 'theme_mode', 'active_brew_v1']) {
      final v = prefs.getString(key);
      if (v != null) {
        await setString(key, v);
        await prefs.remove(key);
      }
    }

    // Int key → store as decimal string
    final kettle = prefs.getInt('kettle_minutes');
    if (kettle != null) {
      await setString('kettle_minutes', kettle.toString());
      await prefs.remove('kettle_minutes');
    }

    // StringList → JSON array string. The old brew_log was a list of
    // already-json-encoded LogEntry objects; we wrap it again as a JSON
    // array of strings, and LogStore decodes that on read.
    final brewLog = prefs.getStringList('brew_log');
    if (brewLog != null) {
      await setString('brew_log', jsonEncode(brewLog));
      await prefs.remove('brew_log');
    }

    await setString(_migrationFlag, 'done');
  }
}

// =============================================================================
// Category — the top-level grouping shown on Home. Fixed set of 5; not
// user-editable. Each category carries the sensible defaults applied to any
// new sub-type ("Other...") created under it.
// =============================================================================

class DrinkCategory {
  final String name;
  final IconData icon;
  final double defaultVolume;
  final bool brewable;
  final List<int> defaultBrewTimes;

  const DrinkCategory({
    required this.name,
    required this.icon,
    required this.defaultVolume,
    required this.brewable,
    required this.defaultBrewTimes,
  });
}

const drinkCategories = <DrinkCategory>[
  DrinkCategory(
    name: 'Hot Tea',
    icon: Icons.local_cafe,
    defaultVolume: 16,
    brewable: true,
    defaultBrewTimes: [3, 5, 7],
  ),
  DrinkCategory(
    name: 'Cold Tea',
    icon: Icons.emoji_food_beverage,
    defaultVolume: 20,
    brewable: false,
    defaultBrewTimes: [],
  ),
  DrinkCategory(
    name: 'Coffee',
    icon: Icons.coffee,
    defaultVolume: 16,
    brewable: true,
    defaultBrewTimes: [1, 2, 3],
  ),
  DrinkCategory(
    name: 'Soda',
    icon: Icons.local_drink,
    defaultVolume: 12,
    brewable: false,
    defaultBrewTimes: [],
  ),
  DrinkCategory(
    name: 'Bog Standard Water',
    icon: Icons.water_drop,
    defaultVolume: 20,
    brewable: false,
    defaultBrewTimes: [],
  ),
];

DrinkCategory? categoryByName(String name) {
  for (final c in drinkCategories) {
    if (c.name == name) return c;
  }
  return null;
}

// =============================================================================
// Drink — a specific sub-type. Stored persistently. The `type` field IS the
// category name (must match one of [drinkCategories]).
// =============================================================================

class Drink {
  final int id;
  final String type;          // category name
  final String description;   // sub-type name (e.g. "Earl Grey")
  final double defaultVolume;
  final bool brewable;
  final List<int> brewTimes;
  final bool isDefault;       // pre-selected sub-type within its category

  const Drink({
    required this.id,
    required this.type,
    required this.description,
    required this.defaultVolume,
    required this.brewable,
    required this.brewTimes,
    this.isDefault = false,
  });

  Drink copyWith({
    int? id,
    String? type,
    String? description,
    double? defaultVolume,
    bool? brewable,
    List<int>? brewTimes,
    bool? isDefault,
  }) =>
      Drink(
        id: id ?? this.id,
        type: type ?? this.type,
        description: description ?? this.description,
        defaultVolume: defaultVolume ?? this.defaultVolume,
        brewable: brewable ?? this.brewable,
        brewTimes: brewTimes ?? this.brewTimes,
        isDefault: isDefault ?? this.isDefault,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'desc': description,
        'vol': defaultVolume,
        'brew': brewable,
        'times': brewTimes,
        'def': isDefault,
      };

  factory Drink.fromJson(Map<String, dynamic> j) => Drink(
        id: j['id'] as int,
        type: j['type'] as String,
        description: j['desc'] as String,
        defaultVolume: (j['vol'] as num).toDouble(),
        brewable: j['brew'] as bool,
        brewTimes: (j['times'] as List).cast<int>(),
        isDefault: (j['def'] as bool?) ?? false,
      );
}

const _seedDrinks = <Drink>[
  // Hot Tea
  Drink(id: 1, type: 'Hot Tea', description: 'Ginger', defaultVolume: 16, brewable: true, brewTimes: [3, 5, 7]),
  Drink(id: 2, type: 'Hot Tea', description: 'Green Tea', defaultVolume: 16, brewable: true, brewTimes: [3, 5, 7], isDefault: true),
  Drink(id: 3, type: 'Hot Tea', description: 'Earl Grey', defaultVolume: 16, brewable: true, brewTimes: [3, 5, 7]),
  Drink(id: 4, type: 'Hot Tea', description: 'Breathe Easy', defaultVolume: 16, brewable: true, brewTimes: [3, 5, 7]),
  // Cold Tea
  Drink(id: 5, type: 'Cold Tea', description: 'Triple Berry', defaultVolume: 20, brewable: false, brewTimes: [], isDefault: true),
  Drink(id: 6, type: 'Cold Tea', description: 'Iced Tea', defaultVolume: 20, brewable: false, brewTimes: []),
  // Coffee
  Drink(id: 7, type: 'Coffee', description: 'Black', defaultVolume: 16, brewable: true, brewTimes: [1, 2, 3]),
  Drink(id: 8, type: 'Coffee', description: 'Cream', defaultVolume: 16, brewable: true, brewTimes: [1, 2, 3]),
  Drink(id: 9, type: 'Coffee', description: 'Cream & Sugar', defaultVolume: 16, brewable: true, brewTimes: [1, 2, 3], isDefault: true),
  // Soda
  Drink(id: 10, type: 'Soda', description: 'Diet Coke', defaultVolume: 42, brewable: false, brewTimes: []),
  Drink(id: 11, type: 'Soda', description: 'Diet Pepsi', defaultVolume: 12, brewable: false, brewTimes: [], isDefault: true),
  Drink(id: 12, type: 'Soda', description: 'Fresca', defaultVolume: 12, brewable: false, brewTimes: []),
  // Bog Standard Water
  Drink(id: 13, type: 'Bog Standard Water', description: 'Water', defaultVolume: 20, brewable: false, brewTimes: [], isDefault: true),
];

/// Reactive drinks list. Any screen that wants to follow drink changes can
/// wrap a [ValueListenableBuilder] around this.
final ValueNotifier<List<Drink>> drinksNotifier =
    ValueNotifier<List<Drink>>(const []);

class DrinksStore {
  // v2: introduces categories + isDefault. v1 (flat type/description list)
  // is intentionally NOT migrated — users get a clean reseed.
  static const _key = 'drinks_v2';

  static Future<List<Drink>> load() async {
    final raw = await SecureStore.getString(_key);
    List<Drink> list;
    if (raw == null) {
      list = List<Drink>.of(_seedDrinks);
      await _save(list);
    } else {
      final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      list = decoded.map(Drink.fromJson).toList();
    }
    drinksNotifier.value = List.unmodifiable(list);
    return list;
  }

  static Future<void> _save(List<Drink> list) async {
    await SecureStore.setString(
      _key,
      jsonEncode(list.map((d) => d.toJson()).toList()),
    );
    drinksNotifier.value = List.unmodifiable(list);
  }

  /// Upsert a drink. If [drink.isDefault] is true, demote any other drink in
  /// the same category to non-default — exactly one default per category.
  static Future<void> upsert(Drink drink) async {
    final list = List<Drink>.of(drinksNotifier.value);
    if (drink.isDefault) {
      for (var i = 0; i < list.length; i++) {
        if (list[i].type == drink.type &&
            list[i].id != drink.id &&
            list[i].isDefault) {
          list[i] = list[i].copyWith(isDefault: false);
        }
      }
    }
    final i = list.indexWhere((d) => d.id == drink.id);
    if (i >= 0) {
      list[i] = drink;
    } else {
      list.add(drink);
    }
    await _save(list);
  }

  static Future<void> remove(int id) async {
    final list = List<Drink>.of(drinksNotifier.value)
      ..removeWhere((d) => d.id == id);
    await _save(list);
  }

  static int nextId() {
    final list = drinksNotifier.value;
    if (list.isEmpty) return 1;
    return list.map((d) => d.id).reduce((a, b) => a > b ? a : b) + 1;
  }

  static Future<void> resetToDefaults() async {
    await _save(List<Drink>.of(_seedDrinks));
  }

  // ---------------------------------------------------------------------------
  // Category-aware helpers
  // ---------------------------------------------------------------------------

  static List<Drink> byCategory(String categoryName) {
    return drinksNotifier.value
        .where((d) => d.type == categoryName)
        .toList(growable: false);
  }

  /// Returns the drink flagged `isDefault: true` for the category, or — if
  /// none — the first drink in that category. Returns null only if the
  /// category is empty.
  static Drink? defaultFor(String categoryName) {
    final inCategory = byCategory(categoryName);
    if (inCategory.isEmpty) return null;
    for (final d in inCategory) {
      if (d.isDefault) return d;
    }
    return inCategory.first;
  }
}

// =============================================================================
// Log entries — unchanged from v1. Old entries with type "Tea"/"Iced tea"/etc.
// continue to load; they just won't group with the new category names.
// =============================================================================

class LogEntry {
  final int id;
  final DateTime timestamp;
  final int drinkId;
  final String type;
  final String description;
  final double volume;
  final String notes;

  const LogEntry({
    required this.id,
    required this.timestamp,
    required this.drinkId,
    required this.type,
    required this.description,
    required this.volume,
    required this.notes,
  });

  LogEntry copyWith({
    double? volume,
    String? notes,
  }) =>
      LogEntry(
        id: id,
        timestamp: timestamp,
        drinkId: drinkId,
        type: type,
        description: description,
        volume: volume ?? this.volume,
        notes: notes ?? this.notes,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        't': timestamp.toIso8601String(),
        'drinkId': drinkId,
        'type': type,
        'desc': description,
        'vol': volume,
        'notes': notes,
      };

  factory LogEntry.fromJson(Map<String, dynamic> j) {
    final t = DateTime.parse(j['t'] as String);
    final isNewSchema = j.containsKey('drinkId');
    return LogEntry(
      id: isNewSchema
          ? (j['id'] as int)
          : t.microsecondsSinceEpoch,
      timestamp: t,
      drinkId: isNewSchema
          ? (j['drinkId'] as int)
          : ((j['id'] as int?) ?? 0),
      type: j['type'] as String,
      description: j['desc'] as String,
      volume: (j['vol'] as num).toDouble(),
      notes: (j['notes'] as String?) ?? '',
    );
  }
}

class LogStore {
  static const _key = 'brew_log';

  static Future<List<LogEntry>> load() async {
    // FlutterSecureStorage only stores strings, so the brew log is a JSON
    // ARRAY of entry-JSON strings rather than a StringList. The migration
    // step in SecureStore wraps the legacy StringList into this format.
    final raw = await SecureStore.getString(_key);
    if (raw == null || raw.isEmpty) return <LogEntry>[];
    final outer = jsonDecode(raw) as List;
    return outer
        .map((s) => LogEntry.fromJson(jsonDecode(s as String) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> _saveAll(List<LogEntry> entries) async {
    final list = entries.map((e) => jsonEncode(e.toJson())).toList();
    await SecureStore.setString(_key, jsonEncode(list));
  }

  static Future<LogEntry> logDrink({
    required Drink drink,
    required double volume,
    String notes = '',
    DateTime? timestamp,
  }) async {
    final t = timestamp ?? DateTime.now();
    final entry = LogEntry(
      id: t.microsecondsSinceEpoch,
      timestamp: t,
      drinkId: drink.id,
      type: drink.type,
      description: drink.description,
      volume: volume,
      notes: notes,
    );
    final all = await load();
    all.add(entry);
    await _saveAll(all);
    return entry;
  }

  static Future<void> delete(int id) async {
    final all = await load();
    all.removeWhere((e) => e.id == id);
    await _saveAll(all);
  }

  /// Re-add an existing entry with its original id (used for "undo delete").
  static Future<void> insert(LogEntry entry) async {
    final all = await load();
    if (all.any((e) => e.id == entry.id)) return;
    all.add(entry);
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    await _saveAll(all);
  }

  static Future<void> update(LogEntry entry) async {
    final all = await load();
    final i = all.indexWhere((e) => e.id == entry.id);
    if (i >= 0) {
      all[i] = entry;
      await _saveAll(all);
    }
  }
}
