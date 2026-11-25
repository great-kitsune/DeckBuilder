import 'dart:convert';
import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'sync_incremental_test.dart' show Fixture;

void main() {
  test(
    'durable detail checkpoint survives reopen and only fetches remaining data',
    () async {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/catalog';
      final f = Fixture();
      await updateCatalog(path, (_) {}, client: f.client);
      final c = Catalog(sqlite3.open(path));
      addTearDown(c.db.close);
      final deck = c.createDeck('Keep');
      c.addToDeck(deck, DeckZone.material, 'c1', 'e1');
      f.changed['last_update'] = ['c1', 'c2'];
      f.rows['c1']!['effect_raw'] = 'changed';
      final old = c.baseline!['last_successful_sync'];
      final id = c.queueSync(SyncMode.incremental);
      final unstable = MockClient((r) async {
        if (r.url.path == '/cards/c2') throw const SocketException('offline');
        return f.client.get(r.url);
      });
      await expectLater(
        updateCatalog(path, (_) {}, client: unstable, jobId: id),
        throwsA(isA<Exception>()),
      );
      expect(c.job(id)!['status'], 'paused');
      expect(c.job(id)!['completed'], 1);
      expect(c.baseline!['last_successful_sync'], old);
      expect(c.deckEntries(deck).single.edition, 'e1');
      f.calls.clear();
      await updateCatalog(path, (_) {}, jobId: id, client: f.client);
      expect(c.job(id)!['status'], 'completed');
      expect(f.calls.where((u) => u.path == '/cards/c1'), isEmpty);
      expect(f.calls.where((u) => u.path == '/cards/c2'), hasLength(1));
    },
  );
  test(
    'cancellation from a second connection stops before publication and drops scratch',
    () async {
      final dir = Directory.systemTemp.createTempSync();
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/catalog';
      final c = Catalog(sqlite3.open(path));
      addTearDown(c.db.close);
      c.createDeck('keep');
      final id = c.queueSync(SyncMode.initial);
      final f = Fixture();
      final client = MockClient((r) async {
        if (r.url.path == '/cards/search') {
          await cancelSync(path, c, id);
        }
        return f.client.get(r.url);
      });
      await updateCatalog(path, (_) {}, jobId: id, client: client);
      expect(c.job(id)!['status'], 'cancelled');
      expect(c.updated, isNull);
      expect(c.decks().single.name, 'keep');
      expect(Directory(syncDirectory(path, id)).existsSync(), false);
    },
  );
  test(
    'full collection revalidates its prefix boundary before resuming',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final c = Catalog(db);
      final id = c.queueSync(SyncMode.initial);
      var fullPages = 0;
      final client = MockClient((r) async {
        final filter = r.url.queryParameters.keys.any(
          (k) => k.endsWith('update'),
        );
        final p = int.parse(r.url.queryParameters['page']!);
        if (!filter) fullPages++;
        return http.Response(
          jsonEncode({
            'page': p,
            'total_pages': filter ? 0 : 3,
            'data': filter
                ? []
                : [
                    {'uuid': 'c$p'},
                  ],
          }),
          200,
        );
      });
      CheckpointApi api() => CheckpointApi(
        client,
        c,
        db,
        id,
        'scratch',
        '2026-01-01T00:00:00Z',
        SyncMode.initial,
      );
      final first = api();
      await first.indexReady('index', null);
      Future<dynamic> page(OfficialApi a, int p) => a.read('/cards/search', {
        'page': '$p',
        'page_size': '50',
        'sort': 'name',
      });
      await page(first, 1);
      await page(first, 2);
      final resumed = api();
      await resumed.indexReady('index', null);
      await resumed.beginFull();
      await page(resumed, 1);
      await page(resumed, 2);
      await page(resumed, 3);
      expect(fullPages, 4);
      await resumed.indexReady('different', null);
      await resumed.beginFull();
      await page(resumed, 1);
      expect(fullPages, 5);
    },
  );
}
