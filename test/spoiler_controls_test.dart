import 'dart:convert';

import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/search_view.dart';
import 'package:deck_builder/spoiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'catalog_test.dart' show card, edition;

void main() {
  late Catalog db;
  setUp(() => db = Catalog(sqlite3.openInMemory()));
  tearDown(() => db.db.close());

  testWidgets(
    'desktop form offers choices before installation and leaves bottom space',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: SpoilerForm(db),
        ),
      );
      expect(tester.getBottomLeft(find.byType(SingleChildScrollView)).dy, 720);
      await tester.tap(find.text('Type'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilterChip, 'ALLY'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile form stores selected search facets and reserves the bottom tenth',
    (tester) async {
      db.insert({
        ...card('a', 'Example', prints: [edition('e', 'SET', '001', 3)]),
        'classes': ['MAGE', 'CLERIC'],
        'elements': ['FIRE', 'WATER'],
        'subtypes': ['TEST SUBTYPE'],
      });
      db.setMetadata('updated', 'installed');
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute<bool>(builder: (_) => SpoilerForm(db)),
                ),
                child: const Text('등록'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('등록'));
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(find.byType(SingleChildScrollView)).dy, 720);
      await tester.enterText(find.byType(TextFormField).first, 'Preview');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Future<void> select(String group, List<String> values) async {
        await tap(find.text(group));
        for (final value in values) {
          final chip = find.widgetWithText(
            group == 'Speed' || group == 'Rarity' ? ChoiceChip : FilterChip,
            value,
          );
          await tap(chip);
        }
        await tap(find.text(group));
      }

      await select('Type', ['ALLY', 'ITEM']);
      await select('Subtype', ['TEST SUBTYPE']);
      await select('Class', ['MAGE', 'CLERIC']);
      await select('Element', ['FIRE', 'WATER']);
      await select('Speed', ['SLOW', 'FAST']);
      await select('Rarity', ['3']);
      await tap(find.text('카드 저장'));
      final row = db.db.select('SELECT payload FROM spoiler_cards').single;
      final payload = jsonDecode(row['payload'] as String);
      expect(payload['types'], ['ALLY', 'ITEM']);
      expect(payload['subtypes'], ['TEST SUBTYPE']);
      expect(payload['classes'], ['MAGE', 'CLERIC']);
      expect(payload['elements'], ['FIRE', 'WATER']);
      expect(payload['speed'], true);
      expect(
        db.db.select('SELECT rarity FROM spoiler_editions').single['rarity'],
        '3',
      );
      final filters = Filters()
        ..text = 'Preview'
        ..selected.addAll({
          'Type': {'ALLY', 'ITEM'},
          'Subtype': {'TEST SUBTYPE'},
          'Speed': {'FAST'},
          'Rarity': {'3'},
        })
        ..all.add('Type');
      expect(db.search(filters), hasLength(1));
    },
  );

  testWidgets(
    'search detail confirms deletion and refreshes the catalog and affected decks',
    (tester) async {
      db.insert(
        card(
          'local',
          'Preview',
          cost: 'reserve',
          prints: [edition('pe', 'SET', '001', 1)],
        ),
        spoiler: true,
      );
      db.insert(card('official', 'Released'));
      final deck = db.createDeck('Deck');
      db.addToDeck(deck, DeckZone.main, 'local', null);
      db.addToDeck(deck, DeckZone.sideboard, 'local', null);
      db.addToDeck(deck, DeckZone.material, 'official', null);
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchView(db, revision: 0, onCatalogChange: () => changes++),
          ),
        ),
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      Future<void> request() async {
        await tester.scrollUntilVisible(
          find.text('카드 삭제'),
          300,
          scrollable: find
              .descendant(
                of: find.byType(CardDetail),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.text('카드 삭제'));
        await tester.pumpAndSettle();
        expect(find.textContaining('덱 1개에서 총 2장'), findsOneWidget);
      }

      await request();
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(db.deckEntries(deck), hasLength(3));
      await request();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(changes, 1);
      expect(find.text('Preview'), findsNothing);
      expect(db.deckEntries(deck).single.card, 'official');
      for (final table in [
        'spoiler_cards',
        'spoiler_tags',
        'spoiler_editions',
      ]) {
        expect(db.db.select('SELECT * FROM $table'), isEmpty);
      }
      await tester.tap(find.text('Released'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(OutlinedButton, '카드 삭제', skipOffstage: false),
        findsNothing,
      );
    },
  );

  test('changed usage and resolved or official cards are protected', () {
    db.insert(card('local', 'Preview'), spoiler: true);
    db.insert(card('a', 'Official'));
    final usage = db.spoilerUsage('local');
    final deck = db.createDeck('D');
    db.addToDeck(deck, DeckZone.material, 'local', null);
    expect(
      () => db.deleteSpoiler('local', confirmedUsage: usage),
      throwsStateError,
    );
    expect(db.deckEntries(deck).single.card, 'local');
    db.transaction(() => db.resolve('local', 'a'));
    for (final id in ['local', 'a']) {
      expect(
        () => db.deleteSpoiler(id, confirmedUsage: db.spoilerUsage(id)),
        throwsStateError,
      );
    }
    expect(db.deckEntries(deck).single.card, 'a');
    expect(db.db.select('SELECT * FROM replacements'), hasLength(1));
  });
}
