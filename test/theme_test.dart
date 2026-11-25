import 'dart:convert';
import 'dart:io';
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/theme_repository.dart';
import 'package:deck_builder/theme_selection_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

final pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQUDAAAACkAGE0Zn1yAAAAAElFTkSuQmCC',
);
void seed(Catalog c) {
  Json print(String id, List<Map<String, String>> files) => {
    ...edition(id, 'S', '001', 1),
    'slug': 'one-$id',
    'last_update': 'edition-v',
    'graphics': {'banner': files},
  };
  c.insert(
    card(
      'a',
      'Artwork',
      prints: [
        print('p', [
          {
            'image': '/graphics/editions/p/banner/tall.jpg',
            'name': 'tall',
            'last_update': 'v2',
          },
        ]),
        print('q', [
          {'image': '/cards/images/opaque.jpg', 'name': 'banner/tall.jpg'},
        ]),
        print('bad', [
          for (final path in [
            '/graphics/editions/other/banner/tall.jpg',
            '/cards/images/../a/tall.jpg',
            '//other/tall.jpg',
            'https://external.example/tall.jpg',
            '/cards/images/%2e%2e/tall.jpg',
          ])
            {'name': 'tall', 'image': path},
          {'name': 'wide', 'image': '/cards/images/wide.jpg'},
        ]),
        edition('no-graphics', 'S', '004', 1),
      ],
    ),
  );
}

void main() {
  test(
    'candidates require an official banner record, exact edition path and filename',
    () {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      seed(c);
      final picks = graphicThemes(c);
      expect(picks.map((g) => g.edition), ['p', 'q']);
      expect(picks.first.version, 'v2');
      expect(picks.last.version, 'edition-v');
      expect(picks.first.slug, 'one-p');
    },
  );
  testWidgets(
    'selection survives restart, failure, catalog refresh and backup restore offline',
    (tester) async {
      await tester.runAsync(() async {
        final dir = Directory.systemTemp.createTempSync();
        final path = '${dir.path}/catalog.sqlite';
        var c = Catalog(sqlite3.open(path));
        try {
          seed(c);
          final choices = graphicThemes(c);
          await selectGraphicTheme(
            c,
            choices.first,
            load: (_, _) async => pixel,
          );
          await expectLater(
            selectGraphicTheme(
              c,
              choices.last,
              load: (_, _) async => throw const SocketException('offline'),
            ),
            throwsException,
          );
          c.db.close();
          c = Catalog(sqlite3.open(path));
          expect((await readGraphicTheme(c))!.image, orderedEquals(pixel));
          final stagePath = '${dir.path}/update.sqlite';
          final stage = Catalog(sqlite3.open(stagePath));
          stage.insert(card('new', 'Another'));
          stage.db.close();
          c.publish(stagePath);
          expect(graphicThemes(c), isEmpty);
          expect((await readGraphicTheme(c))!.edition, 'p');
          final zip = createBackup(path, false, '1');
          final plan = prepareRestore(zip, false, dir.path);
          resetGraphicTheme(c);
          expect(await readGraphicTheme(c), isNull);
          applyRestore(c, plan);
          expect((await readGraphicTheme(c))!.overlay, .6);
          c.setMetadata(graphicSetting, 'broken');
          expect(await readGraphicTheme(c), isNull);
        } finally {
          c.db.close();
          dir.deleteSync(recursive: true);
        }
      });
    },
  );
  testWidgets('search and select an edition and return to default', (
    tester,
  ) async {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    seed(c);
    final selected = ValueNotifier<SelectedGraphic?>(null);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ThemeSelectionView(
          c,
          selected,
          select: (db, g) async => (
            edition: g.edition,
            path: g.path,
            version: g.version,
            overlay: .60,
            image: pixel,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'other');
    await tester.pump();
    expect(find.text('선택할 테마가 없습니다.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'art');
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(('q', '/cards/images/opaque.jpg'))),
    );
    await tester.pump();
    expect(selected.value!.edition, 'q');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey(('q', '/cards/images/opaque.jpg'))),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('기본 테마'));
    await tester.pump();
    expect(selected.value, isNull);
  });
}
