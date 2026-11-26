import 'package:deck_builder/catalog.dart';
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
    ]) {
      expect(() => bo3Preview(sets), throwsStateError);
    }
    expect(changeSet([w, l, w], 0, d), [d, null, null]);
    expect(changeSet([w, l, w], 0, null), [null, null, null]);
    expect(changeSet([w, l, w], 1, null), [w, null, null]);
    expect(changeSet([w, l, w], 2, l), [w, l, l]);
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
