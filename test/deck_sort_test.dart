import 'dart:convert';
import 'package:deck_builder/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

void main() {
  test(
    'zones sort by element group, exalted, numeric cost, type, name and identities',
    () {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      final deck = c.createDeck('Sort');
      void add(
        String id,
        List<String> elements,
        Object? value,
        List<String> types, {
        String? name,
        String cost = 'reserve',
        bool spoiler = false,
      }) {
        c.insert({
          ...card(id, name ?? id, prints: [edition('p$id', 'S', id, 1)]),
          'elements': elements,
          'cost': {'type': cost, 'value': value},
          'types': types,
        }, spoiler: spoiler);
        c.addToDeck(deck, DeckZone.sideboard, id, 'p$id');
      }

      add('x', [], 'X', ['CHAMPION']);
      add('null', [], null, ['CHAMPION']);
      add('unknown', [], '?', ['ITEM']);
      add('e', ['FIRE', 'EXALTED'], 0, ['ACTION']);
      add('n', ['WATER', 'NORM'], 99, ['ALLY']);
      add('a', ['FIRE'], '10', ['ACTION']);
      add('w', ['WIND'], '2', ['WEAPON'], spoiler: true);
      add('t', ['WATER'], 2, ['ATTACK']);
      add('b', ['FIRE'], 2, ['ITEM', 'ACTION'], cost: 'memory');
      add('m', ['FIRE'], 1, ['ITEM']);
      add('a2', [], 2, ['ACTION'], name: ' twins ');
      add('a1', [], 2, ['ACTION'], name: 'Twins');
      add('named', [], 2, ['ACTION'], name: 'Earlier');
      final rows = c.deckEntries(deck);
      expect(rows.map((e) => e.card), [
        'n',
        'm',
        'b',
        't',
        'w',
        'a',
        'e',
        'named',
        'a1',
        'a2',
        'x',
        'null',
        'unknown',
      ]);
      expect(
        rows.every(
          (e) =>
              e.zone == DeckZone.sideboard &&
              e.quantity == 1 &&
              e.edition == 'p${e.card}',
        ),
        true,
      );
      const types = [
        'CHAMPION',
        'ACTION',
        'ATTACK',
        'ALLY',
        'PHANTASIA',
        'DOMAIN',
        'REGALIA',
        'WEAPON',
        'ITEM',
        'OTHER',
      ];
      for (final (i, type) in types.indexed) {
        expect(deckSortKey(null, null, jsonEncode([type])).type, i);
      }
      c.incrementEntry(rows.first);
      expect(c.deckEntries(deck).first.quantity, 2);
      c.takeCopies(c.deckEntries(deck).first, 1, to: DeckZone.main);
      expect(
        c.deckEntries(deck).where((e) => e.zone == DeckZone.main).single.card,
        'n',
      );
    },
  );
  test('equal card UUID sorts by edition even with reversed insertion', () {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    c.insert(
      card(
        'a',
        'A',
        cost: 'reserve',
        prints: [edition('z', 'S', '2', 1), edition('a', 'S', '1', 1)],
      ),
    );
    final id = c.createDeck('Test');
    for (final e in ['z', 'a']) {
      c.addToDeck(id, DeckZone.main, 'a', e);
    }
    expect(c.deckEntries(id).map((e) => e.edition), ['a', 'z']);
  });
}
