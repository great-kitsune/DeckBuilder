import 'dart:convert';
import 'dart:io';

import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/main.dart';
import 'package:deck_builder/offline_images.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

import 'catalog_test.dart' show card, edition;

void main() {
  late Directory root;
  late String path;
  late Catalog catalog;
  late List<String> requests;
  late MockClient client;
  late String versionB;
  late bool failB;
  const a = '/cards/images/a.jpg', b = '/cards/images/b.jpg';
  setUp(() {
    root = Directory.systemTemp.createTempSync();
    path = '${root.path}/catalog.sqlite';
    catalog = Catalog(sqlite3.open(path));
    versionB = '1';
    failB = false;
    requests = [];
    client = MockClient((request) async {
      final route = request.url.path;
      requests.add(route);
      if (route == a || route == b) {
        if (route == b && failB) return http.Response('missing', 404);
        return http.Response.bytes(
          [1, 2, 3],
          200,
          headers: {'content-type': 'image/jpeg'},
        );
      }
      return http.Response(
        jsonEncode(switch (route) {
          '/cards/all' => [
            {'uuid': 'id', 'slug': 'slug'},
          ],
          '/cards/search' => {
            'total_pages': 1,
            'page': 1,
            'data': [
              card(
                'id',
                'Sword',
                prints: [
                  {...edition('p1', 'A', '1', 1), 'image': a},
                  {
                    ...edition('p2', 'B', '1', 1),
                    'image': b,
                    'last_update': versionB,
                  },
                ],
              ),
            ],
          },
          _ => throw StateError(route),
        }),
        200,
      );
    });
  });
  tearDown(() {
    catalog.db.close();
    client.close();
    root.deleteSync(recursive: true);
  });
  Future<void> install(InstallMode mode) =>
      updateCatalog(path, (_) {}, mode: mode, client: client);

  test(
    'existing text upgrades using image requests only; incomplete installs can resume',
    () async {
      catalog.setMetadata('wifiOnly', '1');
      await install(InstallMode.text);
      expect(requests, ['/cards/all', '/cards/search']);
      final snapshot = catalog.updated;
      final dir = offlineImageDirectory(root);
      expect(dir.existsSync(), false);
      failB = true;
      requests.clear();
      await expectLater(install(InstallMode.full), throwsFormatException);
      expect(catalog.imagesComplete, false);
      expect(requests, [a, b]);
      expect(imageFile(dir, a, '').readAsBytesSync(), [1, 2, 3]);
      expect(dir.listSync(), hasLength(1));
      requests.clear();
      failB = false;
      await install(InstallMode.full);
      expect(requests, [b]);
      expect(catalog.updated, snapshot);
      expect(catalog.imagesComplete, true);
      expect(catalog.useOfflineImages, true);
      expect(dir.listSync(), hasLength(2));
    },
  );

  test(
    'fresh full install, refresh of changed images and switch to text',
    () async {
      await install(InstallMode.full);
      expect(requests, ['/cards/all', '/cards/search', a, b]);
      final dir = offlineImageDirectory(root);
      expect(imageFile(dir, b, '1').existsSync(), true);
      requests.clear();
      versionB = '2';
      await install(InstallMode.full);
      expect(requests, ['/cards/all', '/cards/search', b]);
      expect(imageFile(dir, b, '1').existsSync(), false);
      expect(imageFile(dir, b, '2').existsSync(), true);
      expect(dir.listSync(), hasLength(2));
      requests.clear();
      await install(InstallMode.text);
      expect(requests, ['/cards/all', '/cards/search']);
      expect(dir.existsSync(), false);
      expect(catalog.imagesComplete, false);
      expect(catalog.useOfflineImages, false);
      expect(catalog.search(Filters()), hasLength(1));
    },
  );

  testWidgets('text users can cancel or confirm an images-only upgrade', (
    tester,
  ) async {
    InstallMode? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDialog<InstallMode>(
                context: context,
                builder: (_) => const InstallDialog(
                  hasText: true,
                  hasImages: false,
                  offlineRequested: false,
                ),
              );
            },
            child: const Text('설치 방식 선택'),
          ),
        ),
      ),
    );
    Future<void> selectFull() async {
      await tester.tap(find.text('설치 방식 선택'));
      await tester.pumpAndSettle();
      expect(find.textContaining('오프라인 이미지만 추가'), findsOneWidget);
      await tester.tap(find.text('텍스트 + 이미지 모두 설치'));
    }

    await selectFull();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await selectFull();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(result, InstallMode.full);
  });
}
