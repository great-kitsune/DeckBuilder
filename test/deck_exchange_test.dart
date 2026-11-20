import 'dart:convert';
import 'dart:ui' as ui;

import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/deck_editor.dart';
import 'package:deck_builder/deck_exchange_view.dart';
import 'package:deck_builder/deck_png.dart';
import 'package:deck_builder/omnidex.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

void main() {
  late Catalog db;
  setUp(() {
    db = Catalog(sqlite3.openInMemory());
    db.insert(card('m', 'Spirit'));
    db.insert({
      ...card(
        'r',
        '불꽃',
        cost: 'reserve',
        prints: [edition('r1', 'A', '01', 1), edition('r2', 'B', '02', 1)],
      ),
      'english_name': 'Flame',
    });
  });
  tearDown(() => db.db.close());

  test(
    'export and import preserve names, sections and totals across editions',
    () {
      final id = db.createDeck('Original');
      db.addToDeck(id, DeckZone.main, 'r', 'r1');
      db.addToDeck(id, DeckZone.main, 'r', 'r2');
      db.addToDeck(id, DeckZone.sideboard, 'r', null);
      db.addToDeck(id, DeckZone.material, 'm', null);
      final raw = omnidexText(db.deckEntries(id));
      expect(
        raw,
        '# Material Deck\n1 Spirit\n\n# Main Deck\n2 Flame\n\n# Sideboard\n1 Flame',
      );
      final restored = db.importRecipe(
        'Restored',
        parseDeckRecipe('\uFEFF${raw.replaceAll('\n', '\r\n')}'),
      );
      expect(omnidexText(db.deckEntries(restored.id)), raw);
      expect(
        db
            .deckEntries(restored.id)
            .firstWhere((e) => e.zone == DeckZone.main)
            .edition,
        'r1',
      );
    },
  );

  test(
    'invalid imports roll back all rows and ambiguous names require a choice',
    () {
      final recipes = [
        '# Main Deck\n1 Flame\n1 Unknown',
        '# Main Deck\n4 Flame\n# Sideboard\n1 Flame',
        '# Other\n1 Flame',
        '1 Flame',
        '# Main Deck\n0 Flame',
        '# Sideboard',
        '# Main Deck\n1 Spirit',
      ];
      for (final text in recipes) {
        expect(
          () => db.importRecipe('New', parseDeckRecipe(text)),
          throwsFormatException,
        );
        expect(db.decks(), isEmpty);
      }
      db.insert(card('another', 'Flame', cost: 'reserve'));
      final lines = parseDeckRecipe('# Main Deck\n1 Flame');
      expect(() => db.importRecipe('Ambiguous', lines), throwsFormatException);
      expect(db.decks(), isEmpty);
      final imported = db.importRecipe(
        'Choice',
        lines,
        choices: {('flame', DeckZone.main): 'another'},
      );
      expect(db.deckEntries(imported.id).single.card, 'another');
    },
  );

  test(
    'validator sends Standard raw text and distinguishes official and transport results',
    () async {
      const raw = '# Main Deck\n2 Flame';
      Future<ValidationResult> check(String body, int code) => validateOmnidex(
        raw,
        MockClient((req) async {
          expect(req.method, 'POST');
          expect(
            req.url.toString(),
            'https://api.gatcg.com/omnidex/decklist-validator',
          );
          expect(jsonDecode(req.body), {'raw': raw, 'format': 'STANDARD'});
          return http.Response(body, code);
        }),
      );
      expect(
        (await check('{"valid":true,"errors":[]}', 200)).status,
        ValidationStatus.valid,
      );
      final invalid = await check(
        '{"valid":false,"errors":[{"deck":"main","line":2,"code":"DECK_LIMIT","message":"2/60"}]}',
        200,
      );
      expect(invalid.status, ValidationStatus.invalid);
      expect(invalid.detail, contains('2행 · main · DECK_LIMIT · 2/60'));
      for (final result in [
        await check('{}', 200),
        await check('service unavailable', 503),
        await validateOmnidex(
          raw,
          MockClient((_) async => throw http.ClientException('offline')),
        ),
      ]) {
        expect(result.status, ValidationStatus.unknown);
      }
    },
  );

  testWidgets(
    'PNG includes off-screen rows and spoilers and decodes as an image',
    (tester) async {
      await tester.runAsync(() async {
        final id = db.createDeck('PNG');
        db.insert(card('s', 'Preview', cost: 'reserve'), spoiler: true);
        db.addToDeck(id, DeckZone.sideboard, 's', null);
        final initial = db.deckEntries(id);
        expect(() => omnidexText(initial), throwsFormatException);
        Future<int> height(List<DeckEntry> entries) async {
          final bytes = await renderDeckPng('전체 덱', entries);
          expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final codec = await ui.instantiateImageCodec(bytes);
          final image = (await codec.getNextFrame()).image;
          try {
            expect(image.width, 960);
            return image.height;
          } finally {
            image.dispose();
            codec.dispose();
          }
        }

        final small = await height(initial);
        final tall = await height(List.filled(50, initial.single));
        expect(tall, greaterThan(small + 1000));
      });
    },
  );

  testWidgets(
    'import from deck list opens the new deck, copy prompts after clipboard success',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(400, 840);
      addTearDown(tester.view.reset);
      final revision = ValueNotifier(0);
      addTearDown(revision.dispose);
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = call.arguments['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeckList(
              db,
              catalogRevision: revision,
              onCatalogChange: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('레시피 불러오기'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '새 덱 이름'),
        'Imported',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Omnidex 레시피'),
        '# Main Deck\n2 Flame',
      );
      await tester.tap(find.text('새 덱으로 저장'));
      await tester.pumpAndSettle();
      expect(find.text('Imported'), findsOneWidget);
      await tester.tap(find.byTooltip('덱 출력 및 검증'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Omnidex 형식 복사'));
      await tester.pumpAndSettle();
      expect(
        clipboard,
        '# Material Deck\n\n# Main Deck\n2 Flame\n\n# Sideboard',
      );
      expect(find.text('복사했습니다. Omnidex에 접속하시겠습니까?'), findsOneWidget);
      await tester.tap(find.text('아니오'));
      await tester.pumpAndSettle();
      expect(find.byType(DeckExportMenu), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
