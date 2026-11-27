import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

void main() {
  test(
    'catalog replacement retains event snapshot, BO3 records and final result',
    () {
      final tmp = Directory.systemTemp.createTempSync();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final catalog = Catalog(sqlite3.openInMemory());
      addTearDown(catalog.db.close);
      catalog.insert(
        card('c', 'Original', prints: [edition('p', 'SET', '1', 1)]),
      );
      final deck = catalog.createDeck('My deck');
      catalog.addToDeck(deck, DeckZone.material, 'c', 'p');
      final id = catalog.saveEvent(
            name: 'Cup',
            date: '2026-11-26',
            format: 'bo3',
            deck: deck,
          ),
          round = catalog.addRound(id);
      catalog.saveRound(
        round,
        stage: 'swiss',
        complete: true,
        sets: ['win', 'win', null],
      );
      catalog.setPlacement(id, 'champion', finish: true);
      catalog.deleteDeck(deck);
      final path = '${tmp.path}/incoming';
      final next = Catalog(sqlite3.open(path));
      next.insert(card('new', 'New'));
      next.db.close();
      catalog.publish(path);
      expect(eventScore(catalog.event(id)), '우승 / 1-0-0');
      expect(catalog.games(round), ['win', 'win', null]);
      final snapshot = jsonDecode(catalog.event(id)['deck_snapshot']);
      expect(snapshot['name'], 'My deck');
      expect(snapshot['entries'].single, {
        'card': 'c',
        'name': 'Original',
        'edition': 'p',
        'zone': 'material',
        'quantity': 1,
      });
    },
  );
  test(
    'restore rejects inconsistent BO3 records before touching the live DB',
    () {
      final tmp = Directory.systemTemp.createTempSync();
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/invalid.sqlite';
      final c = Catalog(sqlite3.open(path));
      addTearDown(c.db.close);
      final id = c.saveEvent(name: 'Cup', date: '2026-11-26', format: 'bo3'),
          round = c.addRound(id);
      c.saveRound(
        round,
        stage: 'swiss',
        complete: true,
        sets: ['win', null, null],
      );
      c.db.execute("UPDATE round_games SET result='loss'");
      final damaged = createBackup(path, false, '3');
      c.db.execute("UPDATE round_games SET result='win'");
      expect(
        () => prepareRestore(damaged, false, tmp.path),
        throwsFormatException,
      );
      expect(c.games(round), ['win', null, null]);
      expect(eventScore(c.event(id)), '최종 성적 미지정 / 1-0-0');
    },
  );
  for (final full in [false, true]) {
    test(
      'format 1 schema 2 backup without tournament tables replaces history (full=$full)',
      () {
        final tmp = Directory.systemTemp.createTempSync();
        addTearDown(() => tmp.deleteSync(recursive: true));
        final path = '${tmp.path}/old.sqlite';
        final old = Catalog(sqlite3.open(path));
        old.createDeck('Original');
        old.db.execute(
          'DROP TABLE round_life; DROP TABLE round_games; DROP TABLE tournament_rounds; DROP TABLE tournaments; PRAGMA user_version=2',
        );
        old.db.close();
        final bytes = createBackup(path, full, '0.1.0+1');
        final archive = ZipDecoder().decodeBytes(bytes);
        final manifest = jsonDecode(
          utf8.decode(archive.findFile('manifest.json')!.content),
        );
        expect(manifest['format_version'], 1);
        expect(manifest['counts'].containsKey('tournaments'), false);
        final c = Catalog(sqlite3.openInMemory());
        addTearDown(c.db.close);
        c.addRound(
          c.saveEvent(name: 'Replaced', date: '2026-11-26', format: 'bo1'),
        );
        applyRestore(c, prepareRestore(bytes, full, tmp.path));
        expect(c.events, isEmpty);
        expect(c.decks().single.name, 'Original');
      },
    );
  }
  for (final full in [false, true]) {
    test(
      'schema 3 backup preserves archived rows and BO3 results (full=$full)',
      () {
        final root = Directory.systemTemp.createTempSync();
        addTearDown(() => root.deleteSync(recursive: true));
        final path = '${root.path}/source.sqlite';
        final source = Catalog(sqlite3.open(path));
        addTearDown(source.db.close);
        final event = source.saveEvent(
          name: 'Cup',
          date: '2026-11-26',
          format: 'bo3',
        );
        final round = source.addRound(event);
        source.saveRound(
          round,
          stage: 'swiss',
          complete: true,
          sets: ['win', 'loss', 'draw'],
        );
        source.setPlacement(event, 'champion', finish: true);
        // Values from the retired tool exist in both kinds of 0.5.0 backup.
        final archived = [round, 2, -4, 7, 2, 9, 1, 7];
        source.db.execute(
          'INSERT INTO round_life VALUES(?,?,?,?,?,?,?,?)',
          archived,
        );
        final plan = prepareRestore(
          createBackup(path, full, '0.5.0+5'),
          full,
          root.path,
        );
        final restored = Catalog(sqlite3.openInMemory());
        addTearDown(restored.db.close);
        applyRestore(restored, plan);
        expect(restored.games(round), ['win', 'loss', 'draw']);
        expect(eventScore(restored.event(event)), '우승 / 0-0-1');
        expect(
          restored.db.select('SELECT * FROM round_life').single.values.toList(),
          archived,
        );
      },
    );
  }
}
