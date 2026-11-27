import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/tournament_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  testWidgets(
    'new tournament through phone form to completed result and deletion',
    (t) async {
      t.view.physicalSize = const Size(390, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      await t.pumpWidget(MaterialApp(home: TournamentList(c)));
      Future<void> tap(String text) async {
        final all = find.text(text);
        if (all.evaluate().isEmpty) {
          await t.scrollUntilVisible(
            all,
            160,
            scrollable: find.byType(Scrollable).last,
          );
        }
        final f = all.last;
        await t.ensureVisible(f);
        await t.tap(f);
        await t.pumpAndSettle();
      }

      await tap('대회 생성');
      await t.enterText(find.byType(TextFormField).first, 'November Cup');
      await tap('BO1');
      await tap('BO3');
      await tap('저장');
      await tap('라운드 추가');
      expect(find.text('Life · 턴 관리'), findsNothing);
      t.view.physicalSize = const Size(800, 390);
      await t.pumpAndSettle();
      for (int i = 1; i <= 3; i++) {
        expect(find.text('$i세트 · 미기록').hitTestable(), findsOneWidget);
      }
      await t.tap(find.widgetWithText(ChoiceChip, '승리').first);
      await t.pumpAndSettle();
      await tap('라운드 완료');
      expect(find.text('최종 성적 미지정 / 1-0-0'), findsOneWidget);
      await tap('대회 종료');
      await tap('우승');
      expect(find.text('우승 / 1-0-0'), findsOneWidget);
      await t.tap(find.byTooltip('대회 삭제'));
      await t.pumpAndSettle();
      await tap('취소');
      expect(c.events, hasLength(1));
      await t.tap(find.byTooltip('대회 삭제'));
      await t.pumpAndSettle();
      await tap('삭제');
      expect(c.events, isEmpty);
      expect(t.takeException(), isNull);
    },
  );
}
