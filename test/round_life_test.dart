import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/round_life.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final full in [false, true]) {
    test(
      'life, turn, history and BO3 games survive reopen and ${full ? 'full' : 'user'} restore',
      () {
        final root = Directory.systemTemp.createTempSync();
        addTearDown(() => root.deleteSync(recursive: true));
        final path = '${root.path}/catalog.sqlite';
        var c = Catalog(sqlite3.open(path));
        addTearDown(() => c.db.close());
        final id = c.saveEvent(name: 'Cup', date: '2026-11-26', format: 'bo3'),
            r = c.addRound(id);
        c.startLife(r, 1, 1, 7);
        c.startLife(r, 2, 9, 10);
        c.adjustLife(r, 1, 1, -5);
        c.nextTurn(r, 1);
        c.switchPlayer(r, 1);
        c.setTurn(r, 1, 9);
        expect(c.round(r)['status'], 'draft');
        expect(c.games(r), [null, null, null]);
        expect(c.life(r, 1)!['life1'], -4);
        c.saveRound(
          r,
          stage: 'swiss',
          complete: true,
          sets: ['win', 'loss', 'draw'],
        );
        c.setPlacement(id, 'champion', finish: true);
        c.adjustLife(r, 1, 2, 0, absolute: true);
        c.db.close();
        c = Catalog(sqlite3.open(path));
        final plan = prepareRestore(
          createBackup(path, full, '0.5.0'),
          full,
          root.path,
        );
        c.deleteEvent(id);
        expect(c.life(r, 1), isNull);
        applyRestore(c, plan);
        expect(eventScore(c.event(id)), '우승 / 0-0-1');
        expect(c.games(r), ['win', 'loss', 'draw']);
        expect(c.life(r, 1)!['turn'], 9);
        expect(c.life(r, 1)!['player'], 1);
        expect(c.life(r, 1)!['life2'], 0);
        c.undoLife(r, 1);
        expect(c.life(r, 1)!['life2'], 7);
        expect(c.life(r, 1)!['life1'], -4);
        expect(c.life(r, 2)!['life1'], 9);
        expect(c.round(r)['result'], 'draw');
      },
    );
  }
}
