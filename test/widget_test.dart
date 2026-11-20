import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/search_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  testWidgets('search works locally and marks spoiler results', (tester) async {
    final store = Catalog(sqlite3.openInMemory());
    addTearDown(store.db.close);
    store.insert({
      'uuid': 'local-x',
      'name': 'Example',
      'editions': [],
    }, spoiler: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SearchView(store, revision: 0, onAdd: () {})),
      ),
    );
    expect(find.text('Example'), findsOneWidget);
    expect(find.text('스포일러'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'absent');
    await tester.pump();
    expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
  });
}
