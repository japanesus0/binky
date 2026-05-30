import 'package:flutter/material.dart';
import 'storage.dart';

class DrinksEditorScreen extends StatelessWidget {
  const DrinksEditorScreen({super.key});

  Future<void> _edit(BuildContext context, Drink? existing,
      {String? presetCategory}) async {
    // Capture the messenger before any awaits so the post-delete snackbar
    // can fire safely after the form pops.
    final messenger = ScaffoldMessenger.of(context);
    final result = await Navigator.push<_DrinkFormResult>(
      context,
      MaterialPageRoute(
        builder: (_) => _DrinkFormScreen(
          drink: existing,
          presetCategory: presetCategory,
        ),
      ),
    );
    if (result == null) return; // user backed out
    if (result.saved != null) {
      await DrinksStore.upsert(result.saved!);
    } else if (result.deleted && existing != null) {
      await DrinksStore.remove(existing.id);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Removed ${existing.description}'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => DrinksStore.upsert(existing),
          ),
        ),
      );
    }
  }

  Future<void> _delete(BuildContext context, Drink d) async {
    final messenger = ScaffoldMessenger.of(context);
    await DrinksStore.remove(d.id);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Removed ${d.description}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => DrinksStore.upsert(d),
        ),
      ),
    );
  }

  Future<void> _newDrink(BuildContext context) async {
    // Ask which category up front; the form doesn't have a default otherwise.
    final cat = await showDialog<DrinkCategory>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add to which category?'),
        children: [
          for (final c in drinkCategories)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c),
              child: Row(
                children: [
                  Icon(c.icon),
                  const SizedBox(width: 12),
                  Text(c.name),
                ],
              ),
            ),
        ],
      ),
    );
    if (cat == null) return;
    if (!context.mounted) return;
    await _edit(context, null, presetCategory: cat.name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit drinks'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'reset') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Reset to defaults?'),
                    content: const Text(
                      'This replaces your drinks list with the seeded '
                      'categories and sub-types. Your log is untouched.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await DrinksStore.resetToDefaults();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('Reset to defaults')),
            ],
          ),
        ],
      ),
      body: ValueListenableBuilder<List<Drink>>(
        valueListenable: drinksNotifier,
        builder: (context, drinks, _) {
          if (drinks.isEmpty) {
            return const Center(child: Text('No drinks yet. Tap + to add one.'));
          }
          // Section list: one section per category, in the canonical order.
          final children = <Widget>[];
          for (final cat in drinkCategories) {
            final inCategory = DrinksStore.byCategory(cat.name);
            if (inCategory.isEmpty) continue;
            children.add(_CategoryHeader(category: cat));
            for (final d in inCategory) {
              children.add(_drinkTile(context, d));
              children.add(const Divider(height: 1));
            }
          }
          return ListView(children: children);
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _newDrink(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _drinkTile(BuildContext context, Drink d) {
    return Dismissible(
      key: ValueKey(d.id),
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
      onDismissed: (_) => _delete(context, d),
      child: ListTile(
        leading: d.isDefault
            ? const Icon(Icons.star, color: Colors.amber)
            : const Icon(Icons.star_border, color: Colors.transparent),
        title: Text(d.description),
        subtitle: Text(
          '${d.defaultVolume.toStringAsFixed(0)} oz'
          '${d.brewable && d.brewTimes.isNotEmpty ? ' · brew ${d.brewTimes.join("/")} min' : ''}',
        ),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _edit(context, d),
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  final DrinkCategory category;
  const _CategoryHeader({required this.category});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(category.icon, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            category.name.toUpperCase(),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the user did in the form. `null` from Navigator.pop means "backed
/// out / cancelled" — neither saved nor deleted.
class _DrinkFormResult {
  final Drink? saved;
  final bool deleted;
  const _DrinkFormResult.saved(Drink d)
      : saved = d,
        deleted = false;
  const _DrinkFormResult.deleted()
      : saved = null,
        deleted = true;
}

class _DrinkFormScreen extends StatefulWidget {
  final Drink? drink;
  /// When creating a new drink, the category was picked up front and passed
  /// in so the form can pre-fill category-appropriate defaults.
  final String? presetCategory;

  const _DrinkFormScreen({this.drink, this.presetCategory});

  @override
  State<_DrinkFormScreen> createState() => _DrinkFormScreenState();
}

class _DrinkFormScreenState extends State<_DrinkFormScreen> {
  late String _category;
  late final TextEditingController _description;
  late final TextEditingController _volume;
  late final TextEditingController _brewTimes;
  late bool _brewable;
  late bool _isDefault;

  @override
  void initState() {
    super.initState();
    final d = widget.drink;
    final cat = d?.type ?? widget.presetCategory ?? drinkCategories.first.name;
    _category = cat;
    _description = TextEditingController(text: d?.description ?? '');

    final catDef = categoryByName(cat);
    final vols = d?.volumePresets ??
        catDef?.volumePresets ??
        const <double>[16.0];
    _volume = TextEditingController(
      text: vols.map((v) => v.toStringAsFixed(0)).join(', '),
    );
    _brewTimes = TextEditingController(
      text: d == null
          ? (catDef?.defaultBrewTimes ?? const <int>[]).join(',')
          : d.brewTimes.join(','),
    );
    _brewable = d?.brewable ?? catDef?.brewable ?? false;
    _isDefault = d?.isDefault ?? false;
  }

  @override
  void dispose() {
    _description.dispose();
    _volume.dispose();
    _brewTimes.dispose();
    super.dispose();
  }

  void _onCategoryChange(String? newCategory) {
    if (newCategory == null || newCategory == _category) return;
    // When the category changes for a new drink, refresh the category-derived
    // defaults so the form stays sensible.
    final isNew = widget.drink == null;
    final catDef = categoryByName(newCategory);
    setState(() {
      _category = newCategory;
      if (isNew && catDef != null) {
        _volume.text = catDef.volumePresets
            .map((v) => v.toStringAsFixed(0))
            .join(', ');
        _brewable = catDef.brewable;
        _brewTimes.text = catDef.defaultBrewTimes.join(',');
      }
    });
  }

  void _save() {
    final desc = _description.text.trim();
    if (desc.isEmpty) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        const SnackBar(content: Text('Description is required.')),
      );
      return;
    }
    // Volumes: parse the comma-separated input, drop empties / non-numbers
    // / non-positives, cap at 3 entries. Fall back to a sensible single
    // 16 oz default if the user blanked the field entirely.
    final vols = _volume.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(double.tryParse)
        .whereType<double>()
        .where((n) => n > 0)
        .take(3)
        .toList();
    if (vols.isEmpty) vols.add(16.0);
    final times = _brewable
        ? _brewTimes.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map(int.tryParse)
            .whereType<int>()
            .where((n) => n > 0)
            .take(3)
            .toList()
        : <int>[];
    final id = widget.drink?.id ?? DrinksStore.nextId();
    Navigator.pop(
      context,
      _DrinkFormResult.saved(Drink(
        id: id,
        type: _category,
        description: desc,
        volumePresets: vols,
        brewable: _brewable,
        brewTimes: times,
        isDefault: _isDefault,
      )),
    );
  }

  Future<void> _confirmDelete() async {
    final drink = widget.drink;
    if (drink == null) return; // shouldn't happen — button is hidden on new
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${drink.description}?'),
        content: const Text(
          'Removes it from your drinks list. Existing log entries that '
          'reference it keep their original labels.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    Navigator.pop(context, const _DrinkFormResult.deleted());
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.drink == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New drink' : 'Edit drink'),
        actions: [
          if (!isNew)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _confirmDelete,
            ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: _save,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in drinkCategories)
                  DropdownMenuItem(
                    value: c.name,
                    child: Row(
                      children: [
                        Icon(c.icon, size: 20),
                        const SizedBox(width: 8),
                        Text(c.name),
                      ],
                    ),
                  ),
              ],
              onChanged: _onCategoryChange,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Description (e.g. Earl Grey)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _volume,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Volume presets (oz, comma-separated, max 3)',
                hintText: '16, 12, 20',
                helperText: 'First entry is the default. Max 3 entries.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('Brewable'),
              subtitle: const Text('Show a brew timer for this drink'),
              value: _brewable,
              onChanged: (v) => setState(() => _brewable = v),
              contentPadding: EdgeInsets.zero,
            ),
            if (_brewable) ...[
              const SizedBox(height: 4),
              TextField(
                controller: _brewTimes,
                decoration: const InputDecoration(
                  labelText: 'Brew presets (minutes, comma-separated)',
                  hintText: '3, 5, 7',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            SwitchListTile(
              title: const Text('Default for category'),
              subtitle: Text(
                  'Pre-selected when you open $_category, and used for long-press quick-log.'),
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }
}
