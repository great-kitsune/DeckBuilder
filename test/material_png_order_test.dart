import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/material_png_order.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card;

void main() {
  const spirit = 'Spirit of Fire',
      dante1 = 'Dante, Prodigal Swain',
      dante2 = 'Dante, Aenean Initiate',
      dante3 = 'Dante, Hemomancer',
      merlin2 = 'Merlin, Memory Thief',
      merlin3 = 'Merlin, Kingslayer',
      assassin = 'Merlin, Brilliant Vestige',
      lorraine = 'Lorraine, Crux Knight',
      charger = 'Backup Charger';
  List<String> order(List<String> names) {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    final deck = c.createDeck('PNG');
    for (final (name, level, classes) in [
      (spirit, 0, ['SPIRIT']),
      (dante1, 1, ['MAGE']),
      (dante2, 2, ['MAGE']),
      (dante3, 3, ['MAGE']),
      (merlin2, 2, ['MAGE']),
      (merlin3, 3, ['WARRIOR', 'MAGE']),
      (assassin, 3, ['ASSASSIN']),
      (lorraine, 3, ['WARRIOR']),
      (charger, null, ['GUARDIAN']),
      ('Zander, Prepared Scout', 1, ['RANGER']),
    ]) {
      if (!names.contains(name)) continue;
      c.insert({
        ...card(name, name),
        'types': [if (level == null) 'ITEM' else 'CHAMPION'],
        'classes': classes,
        'level': level,
      });
      c.addToDeck(deck, DeckZone.material, name, null);
    }
    return materialPngOrder(c, c.deckEntries(deck)).map((e) => e.name).toList();
  }

  for (final (i, expected) in [
    [spirit, dante1, charger],
    [spirit, dante1, dante2, dante3, lorraine, charger],
    [spirit, dante1, merlin2, merlin3, lorraine, assassin, charger],
    [spirit, dante1, dante2, 'Zander, Prepared Scout', charger],
  ].indexed) {
    test(
      'Material PNG ordering example ${i + 1}',
      () => expect(order(expected.reversed.toList()), expected),
    );
  }
}
