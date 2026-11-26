import 'dart:convert';
import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late String path;
  late Catalog c;
  late String id;
  setUp(() {
    temp = Directory.systemTemp.createTempSync();
    path = '${temp.path}/catalog.sqlite';
    c = Catalog(sqlite3.open(path));
    id = c.saveEvent(
      name: 'Store Cup',
      date: '2026-11-26',
      format: 'bo1',
      deck: c.createDeck('Dante'),
    );
  });
  tearDown(() {
    c.db.close();
    temp.deleteSync(recursive: true);
  });
  test('BO1 requires a result, edits one row and reopens unfinished', () {
    final r = c.addRound(id);
    void save(String? result, bool complete) =>
        c.saveRound(r, stage: 'swiss', complete: complete, result: result);
    expect(() => save(null, true), throwsStateError);
    for (final result in matchResults.keys) {
      save(result, true);
      expect(c.round(r)['result'], result);
    }
    save(null, false);
    expect(c.round(r)['status'], 'draft');
    expect(c.rounds(id), hasLength(1));
    expect(
      () => c.saveEvent(id: id, name: 'Cup', date: '2026-11-26', format: 'bo3'),
      throwsA(isA<SqliteException>()),
    );
    c.deleteDeck(c.decks().single.id);
    c.db.close();
    c = Catalog(sqlite3.open(path));
    expect(snapshotName(c.event(id)), 'Dante');
    expect(c.event(id)['deck_id'], isNull);
    expect(jsonDecode(c.event(id)['deck_snapshot'])['entries'], isEmpty);
    c.deleteRound(r);
    c.saveEvent(id: id, name: 'Cup', date: '2026-11-26', format: 'bo3');
    expect(c.event(id)['format'], 'bo3');
  });
  for (final full in [false, true]) {
    test(
      'tournament round survives ${full ? 'full' : 'user'} backup and a failed restore',
      () {
        final round = c.addRound(id);
        c.saveRound(
          round,
          stage: 'top_cut',
          cut: 'final',
          complete: true,
          result: 'win',
        );
        final plan = prepareRestore(
          createBackup(path, full, '2'),
          full,
          temp.path,
        );
        c.deleteEvent(id);
        expect(c.rounds(id), isEmpty);
        applyRestore(c, plan);
        expect(c.round(round)['result'], 'win');
        expect(snapshotName(c.event(id)), 'Dante');
        c.db.execute(
          "CREATE TRIGGER reject_round BEFORE INSERT ON tournament_rounds BEGIN SELECT RAISE(ABORT,'test'); END",
        );
        expect(() => applyRestore(c, plan), throwsA(isA<SqliteException>()));
        expect(c.round(round)['status'], 'completed');
        expect(c.db.select('PRAGMA integrity_check').single.values.first, 'ok');
      },
    );
  }
  for (final v in [0, 1, 2]) {
    test('schema $v upgrades with deck and preferences intact', () {
      c.setMetadata('graphicsTheme', 'keep');
      c.db.execute(
        'DROP TABLE round_games; DROP TABLE round_life; DROP TABLE tournament_rounds; DROP TABLE tournaments',
      );
      c.db.userVersion = v;
      Catalog(c.db);
      expect(c.db.userVersion, 3);
      expect(c.events, isEmpty);
      expect(c.decks().single.name, 'Dante');
      expect(c.metadata('graphicsTheme'), 'keep');
    });
  }
}
