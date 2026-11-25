import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:deck_builder/card_image.dart' show decodableImage;
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/theme_repository.dart';
import 'package:deck_builder/theme_selection_view.dart';
import 'package:deck_builder/theme_background.dart';
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
    'graphics': {
      'banner': [
        ...files,
        if (id == 'p')
          {'name': 'wide', 'image': '/graphics/editions/p/banner/wide.jpg'},
      ],
      if (id == 'p')
        'icon': [
          {'name': 'large', 'image': '/graphics/editions/p/icon/large.jpg'},
        ],
    },
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
          {'name': 'wide', 'image': '/graphics/editions/other/banner/wide.jpg'},
        ]),
        edition('no-graphics', 'S', '004', 1),
      ],
    ),
  );
}

void main() {
  testWidgets('validates landscape artwork at the official wide banner ratio', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff4488cc), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(800, 300);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        expect(await decodableImage(bytes!.buffer.asUint8List()), isTrue);
      } finally {
        image.dispose();
        picture.dispose();
      }
    });
  });
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
  testWidgets(
    'legacy selection loads registered variants, restores offline and responds to window size',
    (tester) async {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      seed(c);
      final seen = <String>[];
      final graphic = await tester.runAsync(() async {
        c.setMetadata(
          graphicSetting,
          jsonEncode({
            'edition': 'p',
            'path': '/graphics/editions/p/banner/tall.jpg',
            'version': 'v2',
            'overlay': .6,
            'image': base64Encode(pixel),
          }),
        );
        final old = (await readGraphicTheme(
          c,
          load: (path, _) async {
            seen.add(path);
            return pixel;
          },
        ))!;
        for (final art in [ThemeArt.large, ThemeArt.wide]) {
          await old.loadVariant(art);
        }
        final restored = (await readGraphicTheme(
          c,
          load: (_, _) async => throw StateError('offline'),
        ))!;
        expect(restored.cached(ThemeArt.large), orderedEquals(pixel));
        expect(restored.cached(ThemeArt.wide), orderedEquals(pixel));
        return restored;
      });
      expect(seen, [
        '/graphics/editions/p/icon/large.jpg',
        '/graphics/editions/p/banner/wide.jpg',
      ]);
      for (final (size, art) in [
        (const Size(400, 601), ThemeArt.tall),
        (const Size(400, 600), ThemeArt.large),
        (const Size(500, 500), ThemeArt.large),
        (const Size(600, 400), ThemeArt.large),
        (const Size(601, 400), ThemeArt.wide),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: size),
              child: ThemeBackground(graphic!),
            ),
          ),
        );
        final image = tester.widget<Image>(find.byType(Image));
        final provider =
            (image.image as ResizeImage).imageProvider as MemoryImage;
        expect(provider.bytes, same(graphic.cached(art)));
        expect(
          image.alignment,
          art == ThemeArt.wide ? Alignment.centerRight : Alignment.center,
        );
      }
    },
  );
  testWidgets('selecting from a wide window downloads the wide image first', (
    tester,
  ) async {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    seed(c);
    final seen = <String>[];
    final selected = await tester.runAsync(
      () => selectGraphicTheme(
        c,
        graphicThemes(c).first,
        preferred: ThemeArt.wide,
        load: (path, _) async {
          seen.add(path);
          return pixel;
        },
      ),
    );
    expect(selected!.primary, ThemeArt.wide);
    expect(seen, ['/graphics/editions/p/banner/wide.jpg']);
  });
  testWidgets(
    'first display requests only the matching artwork and shows primary on failure',
    (tester) async {
      final c = Catalog(sqlite3.openInMemory());
      addTearDown(c.db.close);
      seed(c);
      final requested = <String>[];
      final choice = graphicThemes(c).first;
      final selected = (await tester.runAsync(
        () => selectGraphicTheme(
          c,
          choice,
          load: (path, _) async {
            requested.add(path);
            if (path == choice.path) return pixel;
            throw const SocketException('offline');
          },
        ),
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(801, 400)),
            child: ThemeBackground(selected),
          ),
        ),
      );
      await tester.pump();
      expect(requested, [choice.path, choice.files[ThemeArt.wide]!.path]);
      expect(
        tester.widget<Image>(find.byType(Image)).alignment,
        Alignment.center,
      );
    },
  );
  testWidgets('search and select an edition and return to default', (
    tester,
  ) async {
    final c = Catalog(sqlite3.openInMemory());
    addTearDown(c.db.close);
    seed(c);
    final chosen = await tester.runAsync(
      () => selectGraphicTheme(
        c,
        graphicThemes(c).last,
        load: (_, _) async => pixel,
      ),
    );
    final selected = ValueNotifier<SelectedGraphic?>(null);
    addTearDown(selected.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ThemeSelectionView(
          c,
          selected,
          select: (_, _, {required preferred}) async => chosen!,
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
