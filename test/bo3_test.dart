import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/tournament_views.dart';
import 'package:deck_builder/round_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  const w = 'win', l = 'loss', d = 'draw';
  test('BO3 recorded-set scoring and invalid gaps', () {
    for (final (a, b, c, expected) in [
      (w, null, null, w),
      (l, null, null, l),
      (d, null, null, d),
      (w, w, null, w),
      (l, l, null, l),
      (w, l, null, d),
      (l, w, null, d),
      (w, d, null, w),
      (l, d, null, l),
      (w, l, w, w),
      (w, l, l, l),
      (w, l, d, d),
      (l, w, d, d),
    ]) {
      expect(bo3Preview([a, b, c]), expected);
    }
    for (final sets in [
      [null, w, null],
      [null, null, w],
      [w, null, l],
      [d, w, null],
      [w, d, l],
      [l, d, d],
    ]) {
      expect(() => bo3Preview(sets), throwsStateError);
    }
    expect(changeSet([w, l, w], 0, d), [d, null, null]);
    expect(changeSet([w, l, w], 0, null), [null, null, null]);
    expect(changeSet([w, l, w], 1, d), [w, d, null]);
    expect(() => changeSet([w, d, null], 2, w), throwsStateError);
    expect(changeSet([w, d, null], 1, l), [w, l, null]);
    expect(changeSet([w, l, w], 1, null), [w, null, null]);
    expect(changeSet([w, l, w], 2, l), [w, l, l]);
  });
  test('round labels include only recorded games in order', () {
    for (final (games, label) in <(List<String?>, String)>[
      ([null, null, null], '미기록'),
      ([w, null, null], '승리(O)'),
      ([w, w, null], '승리(OO)'),
      ([d, null, null], '무승부(-)'),
      ([w, d, null], '승리(O-)'),
      ([l, d, null], '패배(X-)'),
      ([w, l, d], '무승부(OX-)'),
      ([l, w, l], '패배(XOX)'),
    ]) {
      expect(roundResultLabel(bo3Preview(games), sets: games), label);
    }
    expect(roundResultLabel(w), '승리');
  });
  late Catalog c;
  late String round;
  setUp(() {
    c = Catalog(sqlite3.openInMemory());
    round = c.addRound(
      c.saveEvent(name: 'BO3', date: '2026-11-26', format: 'bo3'),
    );
  });
  tearDown(() => c.db.close());
  test('completion, edits and tail removal are atomic', () {
    void save(List<String?> sets) =>
        c.saveRound(round, stage: 'swiss', complete: true, sets: sets);
    expect(() => save([null, null, null]), throwsStateError);
    save([w, null, null]);
    expect(c.round(round)['result'], w);
    save([w, l, null]);
    expect(c.round(round)['result'], d);
    save([w, l, l]);
    expect(c.round(round)['result'], l);
    c.db.execute(
      "CREATE TRIGGER fail BEFORE UPDATE ON tournament_rounds BEGIN SELECT RAISE(ABORT,'test'); END",
    );
    expect(() => save([d, null, null]), throwsA(isA<SqliteException>()));
    expect(c.games(round), [w, l, l]);
    c.db.execute('DROP TRIGGER fail');
    save([d, null, null]);
    expect(c.games(round), [d, null, null]);
    c.deleteRound(round);
    expect(c.db.select('SELECT * FROM round_games'), isEmpty);
  });
  testWidgets(
    'second-game draw closes game three and updates both result views',
    (tester) async {
      final id = c.events.single['id'] as String;
      c.saveRound(round, stage: 'swiss', complete: true, sets: [w, l, w]);
      await tester.pumpWidget(MaterialApp(home: TournamentDetail(c, id)));
      await tester.tap(find.text('승리(OXO)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('결과 수정'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '무승부').at(1));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '승리').at(2))
            .onSelected,
        isNull,
      );
      expect(find.text('잠정 결과 · 승리(O-)'), findsOneWidget);
      await tester.tap(find.text('라운드 완료'));
      await tester.pumpAndSettle();
      expect(find.text('승리(O-)'), findsOneWidget);
      expect(c.games(round), [w, d, null]);
      await tester.tap(find.text('승리(O-)'));
      await tester.pumpAndSettle();
      expect(find.text('확정 결과 · 승리(O-)'), findsOneWidget);
    },
  );

  for (final full in [false, true]) {
    testWidgets(
      'historical draw with third game survives restore and cancelled edits (full=$full)',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync();
        addTearDown(() => dir.deleteSync(recursive: true));
        final path = '${dir.path}/legacy.sqlite';
        final old = Catalog(sqlite3.open(path));
        final id = old.saveEvent(
          name: 'Old Cup',
          date: '2026-11-26',
          format: 'bo3',
        );
        final legacyRound = old.addRound(id);
        old.saveRound(
          legacyRound,
          stage: 'swiss',
          complete: true,
          sets: [w, l, l],
        );
        old.db.execute(
          "UPDATE round_games SET result='draw' WHERE round_id=? AND game_number=2",
          [legacyRound],
        );
        old.db.execute(
          "UPDATE tournament_rounds SET result='draw' WHERE id=?",
          [legacyRound],
        );
        old.db.close();
        applyRestore(
          c,
          prepareRestore(createBackup(path, full, '0.6.0+6'), full, dir.path),
        );
        await tester.pumpWidget(MaterialApp(home: TournamentDetail(c, id)));
        for (final confirm in [false, true]) {
          await tester.tap(find.text('무승부(O-X)'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('결과 수정'));
          await tester.pump();
          expect(find.text('잠정 결과 · 승리(O-)'), findsOneWidget);
          await tester.tap(find.text(confirm ? '라운드 완료' : '수정 취소'));
          await tester.pumpAndSettle();
          expect(c.games(legacyRound), confirm ? [w, d, null] : [w, d, l]);
          expect(
            eventScore(c.event(id)),
            confirm ? '최종 성적 미지정 / 1-0-0' : '최종 성적 미지정 / 0-0-1',
          );
        }
      },
    );
  }
  testWidgets(
    'small round editor gates sets and cancels edits to a confirmed result',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.reset);
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute(builder: (_) => RoundView(c, round)),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('열기'));
        await tester.pumpAndSettle();
      }

      await open();
      ChoiceChip chip(int i) => tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '승리').at(i),
      );
      expect(chip(1).onSelected, isNull);
      expect(chip(2).onSelected, isNull);
      await tester.tap(find.widgetWithText(ChoiceChip, '승리').first);
      await tester.pump();
      expect(chip(1).onSelected, isNotNull);
      expect(c.round(round)['status'], 'draft');
      await tester.tap(find.text('라운드 완료'));
      await tester.pumpAndSettle();
      await open();
      await tester.tap(find.text('결과 수정'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, '무승부').first);
      await tester.pump();
      expect(chip(1).onSelected, isNull);
      await tester.tap(find.text('수정 취소'));
      await tester.pumpAndSettle();
      expect(c.round(round)['result'], 'win');
    },
  );
}
