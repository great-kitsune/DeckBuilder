import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/catalog_job.dart';
import 'package:deck_builder/effect_text.dart';
import 'package:deck_builder/search_view.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  test(
    'Wi-Fi only blocks unavailable and mixed transports before any request',
    () async {
      for (final routes in <List<ConnectivityResult>>[
        [],
        [ConnectivityResult.mobile],
        [ConnectivityResult.wifi, ConnectivityResult.ethernet],
      ]) {
        expect(hasWifiOnlyRoute(routes), isFalse);
      }
      expect(hasWifiOnlyRoute([ConnectivityResult.wifi]), isTrue);
      final api = OfficialApi(
        MockClient((_) => throw StateError('unexpected network request')),
        networkAllowed: () async => false,
      );
      await expectLater(api.read('/cards/all'), throwsA(isA<WifiRequired>()));
    },
  );

  test('losing Wi-Fi aborts an in-flight response without retrying', () async {
    var attempts = 0, allowed = true;
    final client = MockClient.streaming((request, body) async {
      attempts++;
      allowed = false;
      final aborted = (request as http.AbortableRequest).abortTrigger!;
      return http.StreamedResponse(
        Stream.fromFuture(
          aborted.then<List<int>>((_) {
            throw http.RequestAbortedException(request.url);
          }),
        ),
        200,
      );
    });
    await expectLater(
      OfficialApi(
        client,
        networkAllowed: () async => allowed,
      ).read('/cards/all'),
      throwsA(isA<WifiRequired>()),
    );
    expect(attempts, 1);
  });

  test('preferences survive reopening and legacy editions retain input order', () {
    final directory = Directory.systemTemp.createTempSync();
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/catalog';
    final legacy = sqlite3.open(path);
    legacy.execute(
      'CREATE TABLE editions(id TEXT PRIMARY KEY,card TEXT,set_code TEXT,number TEXT,rarity TEXT,payload TEXT)',
    );
    legacy.execute(
      "INSERT INTO editions VALUES('z','card',null,null,null,'{}'),('a','card',null,null,null,'{}')",
    );
    legacy.close();
    final first = Catalog(sqlite3.open(path));
    expect(
      first.db
          .select('SELECT id FROM editions ORDER BY position')
          .map((r) => r['id']),
      ['z', 'a'],
    );
    expect(first.wifiOnly, false);
    expect(first.thumbnailGrid, false);
    first.setMetadata('thumbnailGrid', '1');
    first.setMetadata('wifiOnly', '1');
    first.db.close();
    final reopened = Catalog(sqlite3.open(path));
    addTearDown(reopened.db.close);
    expect(reopened.thumbnailGrid, true);
    expect(reopened.wifiOnly, true);
  });

  test(
    'keyword emphasis preserves raw text, repeated words, icons and line breaks',
    () {
      final span = effectSpan({
        'effect_raw': 'Recover then Recover +1 POWER.\nNext.',
        'effect_html':
            'Recover then <span class="effect__label">Recover</span> +1<span class="effect__icon"></span>. Next.',
      });
      expect(span.toPlainText(), 'Recover then Recover +1 POWER.\nNext.');
      expect(
        span.children!
            .whereType<TextSpan>()
            .where((s) => s.style?.fontWeight == FontWeight.bold)
            .single
            .text,
        'Recover',
      );
      expect(
        effectSpan({
          'effect_raw': 'Rest now',
          'effect': '**Rest** now',
        }).children!.whereType<TextSpan>().any(
          (s) => s.text == 'Rest' && s.style?.fontWeight == FontWeight.bold,
        ),
        true,
      );
    },
  );

  testWidgets(
    'thumbnail opens detail showing first API edition above card information',
    (tester) async {
      final store = Catalog(sqlite3.openInMemory());
      addTearDown(store.db.close);
      store.insert({
        'uuid': 'c',
        'name': 'Example',
        'types': ['ALLY'],
        'editions': [
          for (final id in ['z', 'a'])
            {
              'uuid': id,
              'collector_number': id,
              'set': {'name': 'Print $id'},
            },
        ],
      });
      store.setMetadata('thumbnailGrid', '1');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SearchView(store, revision: 0, onAdd: () {})),
        ),
      );
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.text('Example'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Print z #z')).dy,
        lessThan(tester.getTopLeft(find.text('Type · ALLY')).dy),
      );
      expect(find.text('희귀도 · —'), findsOneWidget);
    },
  );
}
