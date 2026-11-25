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
          final bytes = await renderDeckPng(db, '전체 덱', entries);
          expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
          final codec = await ui.instantiateImageCodec(bytes);
          final image = (await codec.getNextFrame()).image;
          try {
            expect(image.width, greaterThan(0));
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
    'PNG wraps at twelve entries per section and keeps the pixel budget',
    (tester) async {
      await tester.runAsync(() async {
        final id = db.createDeck('Rows');
        db.addToDeck(id, DeckZone.main, 'r', null);
        final entry = db.deckEntries(id).single;
        Future<(int, int)> dimensions(int n) async {
          final bytes = await renderDeckPng(db, 'Deck', List.filled(n, entry));
          final header = ByteData.sublistView(bytes);
          return (header.getUint32(16), header.getUint32(20));
        }

        expect(deckTitleSize, 160);
        expect(deckTotalSize, 110);
        final twelve = await dimensions(12),
            thirteen = await dimensions(13),
            twentyFour = await dimensions(24),
            twentyFive = await dimensions(25);
        expect(twelve.$1, 24 * 2 + 12 * 248 + 11 * 14);
        expect(thirteen.$2 - twelve.$2, 348 + 14);
        expect(twentyFour, thirteen);
        expect(twentyFive.$2 - twentyFour.$2, 348 + 14);
        final large = await dimensions(220);
        expect(large.$1, lessThan(twelve.$1));
        expect(large.$1 * large.$2, lessThanOrEqualTo(16000000));
      });
    },
  );
  testWidgets(
    'PNG draws selected artwork and local spoilers with quantity badges on the face',
    (tester) async {
      await tester.runAsync(() async {
        Future<Uint8List> solid(Color color) async {
          final recorder = ui.PictureRecorder();
          ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
          final pic = recorder.endRecording();
          final image = await pic.toImage(50, 70);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          pic.dispose();
          return data!.buffer.asUint8List();
        }

        final red = await solid(const Color(0xffff0000));
        final green = await solid(const Color(0xff00ff00));
        db.insert(
          card(
            'art',
            'Lucia, Reclaimed Blight',
            cost: 'reserve',
            prints: [
              {
                ...edition('p1', 'A', '01', 1),
                'image': '/cards/images/first.jpg',
              },
              {
                ...edition('p2', 'B', '02', 1),
                'image': '/cards/images/second.jpg',
                'last_update': 'v2',
              },
            ],
          ),
        );
        db.insert(
          card('local', 'Preview', cost: 'reserve'),
          spoiler: true,
          photo: green,
        );
        final id = db.createDeck('Images');
        for (var i = 0; i < 4; i++) {
          db.addToDeck(id, DeckZone.main, 'art', 'p2');
        }
        db.addToDeck(id, DeckZone.main, 'local', null);
        db.insert(
          card('broken', 'Unreadable preview', cost: 'reserve'),
          spoiler: true,
          photo: Uint8List.fromList([0, 1]),
        );
        db.addToDeck(id, DeckZone.sideboard, 'broken', null);
        final requests = <(String, String)>[];
        final bytes = await renderDeckPng(
          db,
          'Images',
          db.deckEntries(id),
          load: (path, version) async {
            requests.add((path, version));
            return red;
          },
        );
        expect(requests, [('/cards/images/second.jpg', 'v2')]);
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          int rgb(int x, int y) =>
              data.getUint32((y * image.width + x) * 4) >> 8;
          // Find both source colors in the same row, then inspect the lower center
          // of the first thumbnail for the translucent badge and white digit.
          var top = 0;
          while (top < image.height && rgb(30, top) != 0xff0000) {
            top++;
          }
          expect(top, lessThan(image.height - 348));
          expect(rgb(300, top + 30), 0x00ff00);
          final colors = {
            for (var y = top + 270; y < top + 300; y++)
              for (var x = 126; x < 170; x++) rgb(x, y),
          };
          expect(colors, contains(0xffffff));
          expect(
            colors.any((c) => c > 0 && c <= 0x440000 && (c & 0xffff) == 0),
            isTrue,
          );
        } finally {
          image.dispose();
          codec.dispose();
        }
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
