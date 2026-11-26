import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/tournament_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  for (final format in ['bo1', 'bo3']) {
    test(
      '$format counts completed Swiss rounds once, including edits after closing',
      () {
        final c = Catalog(sqlite3.openInMemory());
        addTearDown(c.db.close);
        final id = c.saveEvent(
          name: 'League',
          date: '2026-11-26',
          format: format,
        );
        void record(
          String round,
          String? result, {
          bool swiss = true,
          bool complete = true,
        }) {
          c.saveRound(
            round,
            stage: swiss ? 'swiss' : 'top_cut',
            cut: 'final',
            complete: complete,
            result: result,
            sets: format == 'bo1'
                ? null
                : [
                    result,
                    result == 'draw' || result == null ? null : result,
                    null,
                  ],
          );
        }

        String score() => eventScore(c.events.single);
        final ids = [for (var i = 0; i < 4; i++) c.addRound(id)];
        for (final (i, r) in ids.indexed) {
          record(r, ['win', 'win', 'loss', 'draw'][i]);
        }
        record(c.addRound(id), 'win', swiss: false);
        record(c.addRound(id), 'win', complete: false);
        expect(score(), '최종 성적 미지정 / 2-1-1');
        c.setPlacement(id, 'champion', finish: true);
        expect(score(), '우승 / 2-1-1');
        record(ids.first, 'loss');
        expect(score(), '우승 / 1-2-1');
        record(ids.first, 'loss', swiss: false);
        expect(score(), '우승 / 1-1-1');
        record(ids.last, null, complete: false);
        expect(score(), '우승 / 1-1-0');
        c.deleteRound(ids[1]);
        expect(score(), '우승 / 0-1-0');
        c.setPlacement(id, 'runner_up');
        expect(score(), '준우승 / 0-1-0');
        expect(c.event(id)['status'], 'completed');
      },
    );
  }
  testWidgets('finish requests all seven placements even without Top Cut', (
    tester,
  ) async {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    final id = c.saveEvent(name: 'Cup', date: '2026-11-26', format: 'bo1');
    await tester.pumpWidget(MaterialApp(home: TournamentDetail(c, id)));
    await tester.tap(find.text('대회 종료'));
    await tester.pumpAndSettle();
    for (final label in ['풀스위스 종료', '스위스 탈락', '16강', '8강', '4강', '준우승', '우승']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('우승'));
    await tester.pumpAndSettle();
    expect(find.text('우승 / 0-0-0'), findsOneWidget);
  });
}
