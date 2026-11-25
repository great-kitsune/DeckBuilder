import 'dart:async';
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
  late Directory root;
  late String path;
  late Catalog live;
  late Fixture api;
  setUp(() async {
    root = Directory.systemTemp.createTempSync();
    path = '${root.path}/catalog.sqlite';
    live = Catalog(sqlite3.open(path));
    api = Fixture();
    await updateCatalog(path, (_) {}, client: api.client);
    api.calls.clear();
  });
  tearDown(() {
    live.db.close();
    root.deleteSync(recursive: true);
  });
  test(
    'overlapping workers share the job and only one performs requests',
    () async {
      final waiting = Completer<void>(), release = Completer<void>();
      final client = MockClient((req) async {
        if (!waiting.isCompleted) {
          waiting.complete();
          await release.future;
        }
        return api.client.get(req.url);
      });
      final id = live.queueSync(SyncMode.incremental);
      final first = updateCatalog(path, (_) {}, jobId: id, client: client);
      await waiting.future;
      expect(live.queueSync(SyncMode.full), id);
      await updateCatalog(path, (_) {}, jobId: id, client: client);
      release.complete();
      await first;
      expect(api.calls, hasLength(4));
      expect(live.job(id)!['requests'], 4);
    },
  );
  test(
    'corrupt scratch file is rebuilt without replacing the live database',
    () async {
      final deck = live.createDeck('Keep');
      live.addToDeck(deck, DeckZone.material, 'c4', 'e4');
      final id = live.queueSync(SyncMode.incremental);
      final dir = Directory(syncDirectory(path, id))..createSync();
      File('${dir.path}/stage.sqlite').writeAsStringSync('incomplete stage');
      await updateCatalog(path, (_) {}, jobId: id, client: api.client);
      expect(live.job(id)!['status'], 'completed');
      expect(live.deckEntries(deck).single.edition, 'e4');
      expect(dir.existsSync(), false);
    },
  );
  test(
    'changing index twice rolls back the attempted update and its watermark',
    () async {
      int indices = 0;
      final old = live.baseline!['last_successful_sync'];
      final client = MockClient((r) async {
        final response = await api.client.get(r.url);
        if (r.url.path != '/cards/all') return response;
        final data = jsonDecode(response.body) as List;
        indices++;
        if (indices.isEven) data[0]['slug'] = 'renamed';
        return http.Response(jsonEncode(data), 200);
      });
      await expectLater(
        updateCatalog(path, (_) {}, client: client),
        throwsA(isA<SyncProblem>()),
      );
      expect(live.baseline!['last_successful_sync'], old);
      expect(live.syncHistory.first['error_code'], 'index_mismatch');
      expect(live.inspect().damaged, 0);
    },
  );
}
