import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync_history_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  testWidgets(
    'recreated data management reads the same durable job and history details',
    (tester) async {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      final id = c.queueSync(SyncMode.incremental);
      c.progress(id, SyncPhase.fetching_details, 18, 42);
      Widget screen() => MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SyncControls(
                c,
                update: ({bool full = false}) async {},
                inspect: () async {},
                cancel: (_) async {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(screen());
      expect(find.textContaining('18 / 42'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(screen());
      expect(find.textContaining('18 / 42'), findsOneWidget);
      await tester.tap(find.text('동기화 기록'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('변경분 업데이트 · 진행 중'));
      await tester.pumpAndSettle();
      expect(find.textContaining(id), findsOneWidget);
      c.endSync(id, SyncStatus.completed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(screen());
      expect(find.textContaining('이미 최신 카드 데이터입니다'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
