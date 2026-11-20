import 'dart:convert';
import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

Json card(String id, String name, {List<Json> prints = const []}) => {
  'uuid': id,
  'name': name,
  'speed': true,
  'types': ['ALLY', 'ITEM'],
  'subtypes': ['MAGE'],
  'effect_raw': 'Recover 1',
  'cost': {'type': 'memory', 'value': '2'},
  'editions': prints,
};
Json edition(String id, String set, String number, int rarity) => {
  'uuid': id,
  'set': {'prefix': set},
  'collector_number': number,
  'rarity': rarity,
};
void main() {
  late Catalog db;
  setUp(() => db = Catalog(sqlite3.openInMemory()));
  tearDown(() => db.db.close());
  test(
    'groups use independent modes and a shared pool of matching editions',
    () {
      db.insert(
        card(
          'a',
          'Sword',
          prints: [edition('p1', 'A', '001', 1), edition('p2', 'B', '001', 2)],
        ),
      );
      final f = Filters()
        ..selected.addAll({
          'Set': {'A'},
          'Rarity': {'2'},
        });
      expect(db.search(f), isEmpty);
      f.selected['Set']!.add('B');
      expect(db.search(f), hasLength(1));
      f.all.add('Set');
      expect(db.search(f), isEmpty);
      f.selected['Rarity']!.add('1');
      f.all.add('Rarity');
      expect(db.search(f), hasLength(1));
      f.editions = true;
      expect(db.search(f), hasLength(2));
      f.selected['Type'] = {'ALLY', 'ITEM'};
      f.all.add('Type');
      f.selected['Subtype'] = {'MAGE', 'SPELL'};
      expect(db.search(f), hasLength(2));
      f.all.add('Subtype');
      expect(db.search(f), isEmpty);
    },
  );
  test('numbers, literal text, speed and Standard filter', () {
    db.insert(card('a', 'Abc'));
    db.insert({
      ...card('b', 'Spoiler'),
      'cost': {'type': 'memory', 'value': 'X'},
    }, spoiler: true);
    expect(db.search(Filters()..minCost = 0), hasLength(1));
    expect(db.search(Filters()..text = '%'), isEmpty);
    expect(db.search(Filters()..text = 'RECOVER'), hasLength(2));
    expect(db.search(Filters()..legality = '제한 없음'), hasLength(1));
    final f = Filters()..selected['Speed'] = {'FAST', 'SLOW'};
    expect(db.search(f), hasLength(2));
    f.all.add('Speed');
    expect(db.search(f), isEmpty);
  });
  test(
    'publishing preserves missing cards and promotes only unambiguous spoilers',
    () {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/snapshot';
      db.insert(card('old', 'Old'));
      db.insert(card('local-a', ' New   Card '), spoiler: true);
      db.insert(
        card('local-b', 'Other', prints: [edition('local-p', 'A', '001', 1)]),
        spoiler: true,
      );
      final stage = Catalog(sqlite3.open(path));
      stage.transaction(() {
        stage.insert(
          card('x', 'New Card', prints: [edition('p', 'A', '001', 1)]),
        );
        stage.insert(card('y', 'Other'));
      });
      stage.db.close();
      db.publish(path);
      expect(
        db.db
            .select('SELECT official_id FROM replacements')
            .single['official_id'],
        'x',
      );
      expect(db.candidates('local-b').toSet(), {'x', 'y'});
      expect(
        db.db
            .select("SELECT active FROM cards WHERE id='old'")
            .single['active'],
        0,
      );
      expect(db.search(Filters()), hasLength(3));
      db.publish(path);
      expect(db.search(Filters()), hasLength(3));
    },
  );
  test('snapshot failure rolls back previous searchable data', () {
    final dir = Directory.systemTemp.createTempSync();
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/snapshot';
    db.insert(
      card('local', 'Local', prints: [edition('collision', 'A', '1', 1)]),
      spoiler: true,
    );
    db.insert(card('old', 'Old'));
    final stage = Catalog(sqlite3.open(path));
    stage.insert(
      card('new', 'New', prints: [edition('collision', 'B', '1', 1)]),
    );
    stage.db.close();
    expect(() => db.publish(path), throwsA(isA<SqliteException>()));
    expect(db.updated, isNull);
    expect(db.search(Filters()).map((r) => r['name']), ['Local', 'Old']);
  });
  test(
    'collect verifies missing index entries with individual requests',
    () async {
      final api = OfficialApi(
        MockClient(
          (req) async => http.Response(
            jsonEncode(switch (req.url.path) {
              '/cards/all' => [
                {'uuid': 'a', 'slug': 'a'},
                {'uuid': 'b', 'slug': 'b'},
              ],
              '/cards/search' => {
                'total_pages': 1,
                'page': 1,
                'data': [card('a', 'A')],
              },
              '/cards/b' => card('b', 'B'),
              _ => throw StateError('unexpected request'),
            }),
            200,
          ),
        ),
      );
      await collect(db, api, (_) {});
      expect(db.search(Filters()), hasLength(2));
    },
  );
}
