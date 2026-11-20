import 'dart:convert';
import 'dart:io';

import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/deck_editor.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

void main() {
  test(
    'deck quantities, selected editions and independent copies survive reopen and text reinstall',
    () async {
      final root = Directory.systemTemp.createTempSync();
      addTearDown(() => root.deleteSync(recursive: true));
      final path = '${root.path}/catalog.sqlite';
      Catalog open() => Catalog(sqlite3.open(path));
      final initial = open();
      final prints = [
        edition('p1', 'A', '001', 1),
        edition('p2', 'B', '002', 2),
      ];
      initial.insert(card('one', 'Twin', prints: prints));
      initial.insert(card('two', 'Twin'));
      final id = initial.createDeck('Draft');
      for (var n = 0; n < 3; n++) {
        initial.addToDeck(id, DeckZone.main, 'one', 'p2');
      }
      initial.takeCopies(
        initial.deckEntries(id).single,
        1,
        to: DeckZone.sideboard,
      );
      initial.addToDeck(id, DeckZone.main, 'one', null);
      initial.addToDeck(id, DeckZone.material, 'two', null);
      final copied = initial.duplicateDeck(initial.decks().single);
      initial.renameDeck(id, 'Saved');
      initial.takeCopies(initial.deckEntries(copied).first, 1);
      final original = initial.deckEntries(id);
      expect(original.map((e) => e.quantity).reduce((a, b) => a + b), 5);
      initial.deleteDeck(copied);
      expect(initial.deckEntries(copied), isEmpty);
      initial.db.close();
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/cards/all'
                ? [
                    for (final i in ['one', 'two']) {'uuid': i, 'slug': i},
                  ]
                : {
                    'page': 1,
                    'total_pages': 1,
                    'data': [
                      card('one', 'Twin', prints: prints),
                      card('two', 'Twin'),
                    ],
                  },
          ),
          200,
        ),
      );
      await updateCatalog(path, (_) {}, client: client);
      final reopened = open();
      addTearDown(reopened.db.close);
      expect(reopened.decks(), [(id: id, name: 'Saved')]);
      expect(reopened.deckEntries(id), original);
      expect(
        original
            .where((e) => e.edition == 'p2')
            .map((e) => (e.zone, e.quantity)),
        unorderedEquals([(DeckZone.main, 2), (DeckZone.sideboard, 1)]),
      );
      final row = original.first;
      expect(
        () => reopened.takeCopies(row, row.quantity + 1, to: DeckZone.material),
        throwsStateError,
      );
      expect(reopened.deckEntries(id), original);
    },
  );

  test(
    'resolving a spoiler merges matching prints and preserves ambiguous references',
    () {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      final id = c.createDeck('Preview');
      c.insert(
        card('local', 'Known', prints: [edition('local-p', 'SET', '07', 1)]),
        spoiler: true,
      );
      c.addToDeck(id, DeckZone.main, 'local', null);
      c.addToDeck(id, DeckZone.sideboard, 'local', null);
      c.insert(card('known', 'Known', prints: [edition('kp', 'SET', '07', 1)]));
      c.addToDeck(id, DeckZone.main, 'known', 'kp');
      c.insert(card('pending', 'Twins'), spoiler: true);
      c.addToDeck(id, DeckZone.material, 'pending', null);
      c.insert(card('first', 'Twins'));
      c.insert(card('second', 'Twins'));
      expect(c.inspect().replaced, 1);
      final entries = c.deckEntries(id);
      expect(entries.singleWhere((e) => e.zone == DeckZone.main).quantity, 2);
      expect(
        entries.singleWhere((e) => e.zone == DeckZone.sideboard).edition,
        'kp',
      );
      expect(
        entries.singleWhere((e) => e.zone == DeckZone.material).status,
        contains('선택 필요'),
      );
      c.transaction(() => c.resolve('pending', 'second'));
      expect(
        c.deckEntries(id).singleWhere((e) => e.zone == DeckZone.material).card,
        'second',
      );
      expect(c.inspect().replaced, 0);
      expect(c.deckEntries(id), hasLength(3));
    },
  );

  testWidgets(
    'thumbnail picker adds the chosen printing and keeps its filters',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1600, 1000);
      addTearDown(tester.view.reset);
      final catalog = Catalog(sqlite3.openInMemory());
      addTearDown(catalog.db.close);
      catalog.setMetadata('thumbnailGrid', '1');
      catalog.insert(
        card(
          'one',
          'Twin',
          prints: [edition('p1', 'A', '001', 1), edition('p2', 'B', '002', 2)],
        ),
      );
      final id = catalog.createDeck('Prints');
      await tester.pumpWidget(
        MaterialApp(
          home: DeckEditor(
            catalog,
            (id: id, name: 'Prints'),
            revision: 0,
            onCatalogChange: () {},
          ),
        ),
      );
      final toggle = find.text('에디션별 보기');
      await tester.scrollUntilVisible(
        toggle,
        350,
        scrollable: find
            .descendant(
              of: find.ancestor(
                of: find.text('검색 필터'),
                matching: find.byType(ListView),
              ),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final variant = find.ancestor(
        of: find.text('B · #002 · 2'),
        matching: find.byType(Card),
      );
      await tester.tap(
        find.descendant(of: variant, matching: find.byTooltip('Twin 한 장 추가')),
      );
      await tester.pumpAndSettle();
      expect(catalog.deckEntries(id).single.edition, 'p2');
      expect(find.text('B #002'), findsOneWidget);
    },
  );

  for (final wide in [false, true]) {
    testWidgets(
      'create, search, edit and move on ${wide ? 'desktop' : 'phone'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(wide ? 1200 : 390, 820);
        addTearDown(tester.view.reset);
        final catalog = Catalog(sqlite3.openInMemory());
        addTearDown(catalog.db.close);
        final revision = ValueNotifier(0);
        addTearDown(revision.dispose);
        catalog.insert(
          card('a', 'Amber', prints: [edition('p', 'Set', '002', 1)]),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DeckList(
                catalog,
                catalogRevision: revision,
                onCatalogChange: () => revision.value++,
              ),
            ),
          ),
        );
        await tester.tap(find.text('새 덱'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'My Deck');
        await tester.pump();
        await tester.tap(find.text('저장'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('add-main')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Amb');
        await tester.pumpAndSettle();
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.byTooltip('Amber 한 장 추가'));
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('덱에 3장'), findsOneWidget);
        expect(find.text('Amb'), findsOneWidget);
        if (!wide) {
          await tester.tap(find.byTooltip('덱으로'));
          await tester.pumpAndSettle();
        }
        expect(find.text('Main Deck · 3장'), findsOneWidget);
        await tester.tap(find.byTooltip('구역 이동'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sideboard로 이동'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('이동'));
        await tester.pumpAndSettle();
        expect(find.text('Main Deck · 2장'), findsOneWidget);
        expect(find.text('Sideboard · 1장'), findsOneWidget);
        await tester.tap(find.byTooltip('한 장 빼기').last);
        await tester.pumpAndSettle();
        expect(find.text('Sideboard · 0장'), findsOneWidget);
        expect(
          catalog.deckEntries(catalog.decks().single.id).single.quantity,
          2,
        );
      },
    );
  }
}
