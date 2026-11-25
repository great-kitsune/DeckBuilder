import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:deck_builder/api_request.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;
import 'sync_incremental_test.dart' show Fixture;

void main() {
  for (final (status, code, expected) in [
    (429, 'rate_limited', 4),
    (503, 'server_error', 4),
    (400, 'invalid_response', 1),
  ]) {
    test('HTTP $status uses the correct retry limit and reason', () async {
      var calls = 0;
      final waits = <Duration>[];
      final client = MockClient((r) async {
        calls++;
        return http.Response('', status, headers: {'retry-after': '120'});
      });
      await expectLater(
        getFromApi(
          client,
          Uri.https('example.org', '/'),
          delay: (d) async => waits.add(d),
        ),
        throwsA(isA<SyncProblem>().having((e) => e.code, 'code', code)),
      );
      expect(calls, expected);
      expect(waits, everyElement(const Duration(seconds: 30)));
    });
  }
  test(
    'timeout is distinct from no network and HTTP dates are bounded',
    () async {
      expect(
        retryAfter(
          'Wed, 25 Nov 2026 08:00:01 GMT',
          DateTime.utc(2026, 11, 25, 8),
        ),
        const Duration(seconds: 1),
      );
      for (final (error, code) in [
        (TimeoutException('slow'), 'network_timeout'),
        (const SocketException('offline'), 'network_unavailable'),
      ]) {
        await expectLater(
          getFromApi(
            MockClient((_) async => throw error),
            Uri.https('example.org', '/'),
            delay: (_) async {},
          ),
          throwsA(isA<SyncProblem>().having((e) => e.code, 'code', code)),
        );
      }
    },
  );
  late Directory root;
  late Catalog db;
  late Fixture f;
  late String path;
  String userHash() {
    final content = [
      for (final t in [
        'decks',
        'deck_entries',
        'spoiler_cards',
        'spoiler_editions',
        'spoiler_tags',
        'replacements',
      ])
        [
          t,
          for (final r in db.db.select('SELECT * FROM $t ORDER BY rowid'))
            r.values.toList(),
        ],
      db.metadata('graphicsTheme'),
    ];
    return sha256.convert(utf8.encode(jsonEncode(content))).toString();
  }

  group('installed DB', () {
    setUp(() async {
      root = Directory.systemTemp.createTempSync();
      path = '${root.path}/catalog';
      db = Catalog(sqlite3.open(path));
      f = Fixture();
      await updateCatalog(path, (_) {}, client: f.client);
      db.setMetadata('graphicsTheme', 'theme');
      db.insert(
        card('sp', 'Preview'),
        spoiler: true,
        photo: Uint8List.fromList([7, 6, 5]),
      );
      db.addToDeck(db.createDeck('saved'), DeckZone.material, 'c1', 'e1');
    });
    tearDown(() {
      db.db.close();
      root.deleteSync(recursive: true);
    });
    for (final problem in [
      'malformed',
      'duplicate',
      'reassigned',
      'parent',
      'pagination',
      'shrink',
      'rollback',
      'storage',
    ]) {
      test(
        '$problem preserves user records, installed snapshot and successful baseline',
        () async {
          final before = userHash(),
              baseline = db.baseline!['last_successful_sync'],
              manifest = db.db
                  .select('SELECT * FROM install_manifest ORDER BY kind,id')
                  .map((r) => r.values.toList())
                  .toList();
          f.rows['c1']!['effect_raw'] = 'proposed';
          if (problem == 'rollback') {
            db.db.execute(
              "CREATE TRIGGER reject BEFORE UPDATE ON cards BEGIN SELECT RAISE(ABORT,'stop'); END",
            );
          }
          if (problem == 'storage') db.db.execute("PRAGMA max_page_count=1");
          final client = MockClient((r) async {
            final res = await f.client.get(r.url);
            final data = jsonDecode(res.body);
            if (problem == 'storage') {
              throw const FileSystemException(
                'full',
                'stage',
                OSError('disk full', 28),
              );
            }
            if (problem == 'shrink' && r.url.path == '/cards/all') {
              return http.Response(
                jsonEncode((data as List).take(1).toList()),
                200,
              );
            }
            if (r.url.path != '/cards/search') return res;
            if (problem == 'malformed') return http.Response('{', 200);
            if (problem == 'reassigned') {
              final first = data['data'][0]['editions'];
              data['data'][0]['editions'] = data['data'][1]['editions'];
              data['data'][1]['editions'] = first;
            }
            if (problem == 'duplicate') data['data'][1] = data['data'][0];
            if (problem == 'parent') {
              data['data'][0]['editions'][0]['card_id'] = 'wrong';
            }
            if (problem == 'pagination') data['page'] = 4;
            return http.Response(jsonEncode(data), 200);
          });
          await expectLater(
            updateCatalog(path, (_) {}, client: client, mode: SyncMode.full),
            throwsA(anything),
          );
          expect(userHash(), before);
          expect(db.baseline!['last_successful_sync'], baseline);
          expect(
            db.db
                .select('SELECT * FROM install_manifest ORDER BY kind,id')
                .map((r) => r.values.toList()),
            manifest,
          );
          expect(
            db.job(db.syncHistory.first['id'] as String)!['status'],
            isNot('completed'),
          );
        },
      );
    }
    test(
      'genuine schema-1 snapshot restores user data and resets only a full restore baseline',
      () {
        final before = userHash();
        final baseline = db.baseline!['index_hash'];
        final legacy = '${root.path}/legacy.sqlite';
        db.db.execute('VACUUM INTO ?', [legacy]);
        final old = sqlite3.open(legacy);
        old.execute(
          'DROP TABLE sync_events; DROP TABLE sync_jobs; DROP TABLE sync_state; DROP TABLE sync_index; PRAGMA user_version=1',
        );
        old.close();
        for (final full in [false, true]) {
          final dir = Directory('${root.path}/restore-$full')..createSync();
          final bytes = createBackup(legacy, full, '1');
          final plan = prepareRestore(bytes, full, dir.path);
          applyRestore(db, plan);
          expect(userHash(), before);
          expect(db.baseline?['index_hash'], full ? null : baseline);
          expect(db.db.userVersion, 2);
          expect(db.inspect().damaged, 0);
        }
      },
    );
    test(
      'unreferenced optional fields and an added/changed back print match full face collection',
      () async {
        final front = f.rows['c1']!;
        void face(String no) {
          (front['editions'] as List).add({
            ...edition('front-$no', 'S', no, 1),
            'other_orientations': [
              {
                ...card('back', 'Back'),
                'edition_id': 'back-$no',
                'edition': {
                  ...edition('back-$no', 'S', no, 1),
                  'card_id': 'back',
                },
              },
            ],
          });
        }

        face('1');
        f.changed['edition_last_update'] = ['c1'];
        final client = MockClient((r) async {
          final res = await f.client.get(r.url);
          if (r.url.path != '/cards/all') return res;
          return http.Response(
            jsonEncode([
              ...jsonDecode(res.body),
              {'uuid': 'back', 'slug': 'back'},
            ]),
            200,
          );
        });
        await updateCatalog(path, (_) {}, client: client);
        face('2');
        await updateCatalog(path, (_) {}, client: client);
        final prints = db.db.select(
          "SELECT id FROM editions WHERE card='back' ORDER BY id",
        );
        expect(prints.map((r) => r['id']), ['back-1', 'back-2']);
      },
    );
  });
}
