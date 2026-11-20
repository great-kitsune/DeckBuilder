import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/search_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  testWidgets('detail viewport follows window height and system padding', (
    tester,
  ) async {
    final store = Catalog(sqlite3.openInMemory());
    addTearDown(store.db.close);
    store.insert({
      'uuid': 'c',
      'name': 'Example',
      'editions': [],
      'rule': [
        for (var i = 0; i < 60; i++) {'title': 'Rule', 'description': '$i'},
      ],
    });
    final view = tester.view;
    addTearDown(view.reset);
    view.devicePixelRatio = 1;
    view.physicalSize = const Size(390, 800);
    view.padding = const FakeViewPadding(bottom: 24);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: CardDetail(store, 'c', null),
      ),
    );
    final list = find.byType(ListView);
    expect(tester.getBottomLeft(list).dy, 720);
    await tester.scrollUntilVisible(
      find.text('Rule 59'),
      400,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.text('Rule 59')).dy,
      lessThanOrEqualTo(720),
    );

    view.physicalSize = const Size(800, 390);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(list).dy, 351);

    view.padding = const FakeViewPadding(bottom: 48);
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(list).dy, 342);

    view.padding = FakeViewPadding.zero;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: CardDetail(store, 'c', null),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(list).dy, 390);
  });
}
