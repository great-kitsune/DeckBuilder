import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deck_builder/card_image.dart';
import 'package:deck_builder/search_view.dart';
import 'package:flutter/material.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

import 'catalog_test.dart' show card, edition;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String path;
  late Catalog catalog;
  setUp(() {
    root = Directory.systemTemp.createTempSync();
    path = '${root.path}/catalog.db';
    catalog = Catalog(sqlite3.open(path));
  });
  tearDown(() {
    catalog.db.close();
    root.deleteSync(recursive: true);
  });

  test(
    'fresh installation and reinstall only request text and record the expected snapshot',
    () async {
      final requests = <String>[];
      final client = MockClient((req) async {
        requests.add(req.url.path);
        return http.Response(
          jsonEncode(switch (req.url.path) {
            '/cards/all' => [
              {'uuid': 'c', 'slug': 'c'},
            ],
            '/cards/search' => {
              'page': 1,
              'total_pages': 1,
              'data': [
                card(
                  'c',
                  'First',
                  prints: [
                    {
                      ...edition('e', 'S', '1', 2),
                      'image': '/cards/images/x.jpg',
                    },
                  ],
                ),
              ],
            },
            _ => throw StateError('Unexpected image request'),
          }),
          200,
        );
      });
      catalog.setMetadata('imageMode', 'full');
      for (var i = 0; i < 2; i++) {
        await updateCatalog(path, (_) {}, client: client);
      }
      expect(requests, [
        '/cards/all',
        '/cards/search',
        '/cards/all',
        '/cards/search',
      ]);
      expect(catalog.inspect(), (
        missing: 0,
        damaged: 0,
        replaced: 0,
        hasManifest: true,
      ));
      catalog.db.execute(
        "DELETE FROM editions WHERE id='e'; UPDATE cards SET effect='changed' WHERE id='c'",
      );
      final report = catalog.inspect();
      expect(report.missing, 1);
      expect(report.damaged, 1);
    },
  );

  test(
    'same name candidates remain distinct and existing spoilers migrate with their photos and references',
    () {
      catalog.insert(
        card('a', 'Nameless', prints: [edition('ea', 'SET', '001', 1)]),
      );
      catalog.insert(
        card('b', 'Nameless', prints: [edition('eb', 'SET', '002', 1)]),
      );
      catalog.insert(card('other', 'Other'));
      // Seed the previous schema representation, including an already-resolved row.
      catalog.insert({
        ...card('local-a', '로컬', prints: [edition('le', 'SET', '002', 1)]),
        'english_name': ' NAMELESS ',
      }, photo: Uint8List.fromList([1, 2]));
      catalog.insert(card('local-b', 'Nameless'));
      catalog.insert(card('local-old', 'Former'));
      catalog.db.execute(
        "UPDATE cards SET spoiler=1 WHERE id LIKE 'local-%'; UPDATE cards SET active=0 WHERE id='local-old'; INSERT INTO replacements VALUES('local-old','other')",
      );
      catalog.db.userVersion = 0; // Legacy installs predate versioned migrations.
      final migrated = Catalog(catalog.db);
      expect(migrated.updated, isNull);
      expect(
        migrated.db.select("SELECT * FROM cards WHERE spoiler=1"),
        isEmpty,
      );
      expect(
        migrated.db
            .select("SELECT photo FROM spoiler_cards WHERE id='local-a'")
            .single['photo'],
        [1, 2],
      );
      expect(
        migrated.db
            .select(
              "SELECT official_id FROM replacements WHERE local_id='local-a'",
            )
            .single['official_id'],
        'b',
      );
      expect(
        migrated.db
            .select(
              "SELECT official_id FROM replacements WHERE local_id='local-old'",
            )
            .single['official_id'],
        'other',
      );
      expect(migrated.candidates('local-b').toSet(), {'a', 'b'});
      expect(
        migrated.db
            .select("SELECT active FROM spoiler_cards WHERE id='local-b'")
            .single['active'],
        2,
      );
      expect(migrated.search(Filters()..text = 'Nameless'), hasLength(2));
      migrated.insert(card('new', 'Other'), spoiler: true);
      migrated.insert(card('unique', 'Still local'), spoiler: true);
      expect(migrated.inspect().replaced, 1);
      expect(migrated.inspect().replaced, 0);
      expect(migrated.search(Filters()..text = 'Still local'), hasLength(1));
    },
  );

  testWidgets('a resolved local reference opens the official card details', (
    tester,
  ) async {
    catalog.insert(
      card(
        'official',
        'Official',
        prints: [edition('edition', 'API', '001', 1)],
      ),
    );
    catalog.insert({
      ...card('local', 'Local preview'),
      'english_name': 'Official',
    }, spoiler: true);
    catalog.inspect();
    await tester.pumpWidget(
      MaterialApp(home: CardDetail(catalog, 'local', null)),
    );
    expect(find.text('Official'), findsOneWidget);
    expect(find.text('API #001'), findsOneWidget);
    expect(find.text('스포일러 · 공식 등록 전'), findsNothing);
  });

  test(
    'only viewed images are cached, shared between readers, and recovered when damaged',
    () async {
      final good = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMQUDAAAACkAGE0Zn1yAAAAAElFTkSuQmCC',
      );
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response.bytes(good, 200);
      });
      final dir = Directory('${root.path}/images');
      Future<Uint8List> view() => viewedImage(
        '/cards/images/a.png',
        'v1',
        directories: [dir],
        client: client,
      );
      await Future.wait([view(), view()]);
      expect(requests, 1);
      expect(await view(), good);
      expect(requests, 1);
      (dir.listSync().single as File).writeAsBytesSync([1, 2, 3]);
      expect(await view(), good);
      expect(requests, 2);
      (dir.listSync().single as File).writeAsBytesSync([0]);
      expect(await removeDamagedImages(directories: [dir]), 1);
      expect(await removeDamagedImages(directories: [dir]), 0);
      expect(requests, 2);
      expect(await view(), good);
      expect(requests, 3);
    },
  );
}
