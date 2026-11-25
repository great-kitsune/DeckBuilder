import 'dart:convert';
import 'catalog.dart';

typedef _Champion = ({DeckEntry entry, int level, bool mage});

int _byLevel(_Champion a, _Champion b) {
  final level = a.level.compareTo(b.level);
  return level != 0 ? level : compareDeckEntries(a.entry, b.entry);
}

class _Lineage {
  final String name;
  final cards = <_Champion>[];
  _Lineage(this.name);
  int get count => cards.map((c) => c.entry.card).toSet().length;
  int get lowest => cards.map((c) => c.level).reduce((a, b) => a < b ? a : b);
}

int _byLineage(_Lineage a, _Lineage b) {
  final count = b.count.compareTo(a.count);
  if (count != 0) return count;
  final level = a.lowest.compareTo(b.lowest);
  return level != 0 ? level : a.name.compareTo(b.name);
}

/// Applies only to the Material section of a PNG. The input is in normal deck order.
List<DeckEntry> materialPngOrder(Catalog catalog, List<DeckEntry> entries) {
  if (entries.length < 2) return entries;
  final rows = catalog.db.select(
    r"""
    SELECT id, payload FROM library_cards
    WHERE id IN (SELECT value FROM json_each(?))
    AND EXISTS (SELECT 1 FROM json_each(payload,'$.types') WHERE upper(value)='CHAMPION')
    """,
    [jsonEncode(entries.map((e) => e.card).toSet().toList())],
  );
  final data = {
    for (final row in rows)
      row['id']: jsonDecode(row['payload'] as String) as Json,
  };
  final spirits = <_Champion>[], mageMerlins = <_Champion>[];
  final groups = <String, _Lineage>{};
  final others = <DeckEntry>[];
  bool contains(Object? values, String code) =>
      values is List &&
      values.whereType<String>().any((s) => s.toUpperCase() == code);
  for (final entry in entries) {
    final card = data[entry.card];
    if (card == null) {
      others.add(entry);
      continue;
    }
    final name = card['english_name']?.toString().trim();
    final lineage = normalizedName(
      (name == null || name.isEmpty ? entry.name : name).split(',').first,
    );
    final level = int.tryParse(card['level'].toString()) ?? 0x7fffffff;
    final champion = (
      entry: entry,
      level: level,
      mage: contains(card['classes'], 'MAGE'),
    );
    if (level == 0 &&
        (contains(card['classes'], 'SPIRIT') ||
            contains(card['subtypes'], 'SPIRIT'))) {
      spirits.add(champion);
    } else if (lineage == 'merlin' && champion.mage) {
      mageMerlins.add(champion);
    } else {
      groups.putIfAbsent(lineage, () => _Lineage(lineage)).cards.add(champion);
    }
  }
  // Choose the strongest eligible Mage base before counting the attached Merlin cards.
  final bases = groups.values.where((g) => g.name != 'merlin').toList()
    ..sort(_byLineage);
  for (final merlin in mageMerlins..sort(_byLevel)) {
    final base = bases
        .where((g) => g.cards.any((c) => c.mage && c.level < merlin.level))
        .firstOrNull;
    (base ?? groups.putIfAbsent('merlin', () => _Lineage('merlin'))).cards.add(
      merlin,
    );
  }
  return [
    for (final spirit in spirits..sort(_byLevel)) spirit.entry,
    for (final group in groups.values.toList()..sort(_byLineage))
      for (final champion in group.cards..sort(_byLevel)) champion.entry,
    ...others,
  ];
}
