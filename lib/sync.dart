import 'dart:convert';
import 'dart:io';
import 'dart:collection';
import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'catalog.dart';
import 'api_request.dart';
import 'sync_lock.dart';

export 'api_request.dart' show SyncProblem;
part 'sync_checkpoint.dart';
part 'sync_validation.dart';

class OfficialApi {
  final http.Client client;
  int requests = 0, bytes = 0;
  OfficialApi(this.client);
  void guard() {}
  Future<void> indexReady(String hash, String? baseline) async {}
  Future<void> beginFull() async {}
  Future<dynamic> detail(String path, Json? candidate) => read(path);

  Future<dynamic> read(String path, [Map<String, String>? query]) async {
    final uri = Uri.https('api.gatcg.com', path, query);
    final response = await getFromApi(
      client,
      uri,
      beforeAttempt: () {
        guard();
        requests++;
      },
      received: (n) => bytes += n,
    );
    guard();
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}

Future<void> collect(
  Catalog stage,
  OfficialApi api,
  void Function(String) report, {
  Map<String, String>? indexAtStart,
  void Function(SyncPhase, int, int?)? progress,
}) async {
  final index = indexAtStart ?? await readIndex(api);
  final missing = Map.of(index);
  final seen = <String>{};
  void insert(Json card) {
    validateCard(card);
    final id = card['uuid'] as String;
    if (!missing.containsKey(id) || !seen.add(id)) {
      throw const SyncProblem(
        'index_mismatch',
        '공식 카드 목록의 UUID가 중복되거나 일치하지 않습니다.',
      );
    }
    stage.insert(card);
    missing.remove(id);
  }

  // Search groups a flip card under its front. One back can have multiple prints.
  final faces = <String, Json>{};
  final facePrints = <String, Map<String, Json>>{};
  void collectFaces(Json front) {
    for (final printing in front['editions'] as List) {
      for (final raw in printing['other_orientations'] as List? ?? []) {
        final face = Json.of(raw as Json);
        final id = face['uuid'] as String;
        final edition = face.remove('edition') as Json;
        face.remove('edition_id');
        if (faces.containsKey(id) &&
            jsonEncode(faces[id]) != jsonEncode(face)) {
          invalidData('양면 카드 정보가 충돌했습니다.');
        }
        final known = facePrints[id]?[edition['uuid']];
        if (known != null && jsonEncode(known) != jsonEncode(edition)) {
          invalidData('양면 인쇄판 정보가 충돌했습니다.');
        }
        faces[id] = face;
        (facePrints[id] ??= {})[edition['uuid'] as String] = edition;
      }
    }
  }

  Future<dynamic> pageData(int page) => api.read('/cards/search', {
    'page': '$page',
    'page_size': '50',
    'sort': 'name',
  });
  int? totalPages;
  for (var page = 1; ; page++) {
    final result = await pageData(page) as Json;
    totalPages ??= result['total_pages'] as int;
    final rows = result['data'] as List;
    validatePage(result, page, totalPages, rows);
    if (result['page'] != page ||
        result['total_pages'] != totalPages ||
        totalPages < page ||
        rows.isEmpty) {
      throw const SyncProblem(
        'pagination_mismatch',
        '카드 페이지가 누락되거나 수집 중 변경되었습니다.',
      );
    }
    stage.transaction(() {
      for (final c in rows.cast<Json>()) {
        insert(c);
        collectFaces(c);
      }
    });
    report('$page / $totalPages 페이지 · ${seen.length} / ${index.length}장');
    progress?.call(SyncPhase.fetching_changes, page, totalPages);
    if (page == totalPages) break;
  }
  // /cards/all can include cards that the paginated search has not indexed yet.
  for (final entry in missing.entries.toList()) {
    Json? card;
    if (!faces.containsKey(entry.key)) {
      final detail = await api.read('/cards/${entry.value}') as Json;
      if (detail['uuid'] == entry.key) {
        card = detail;
      } else {
        collectFaces(detail);
      }
    }
    card ??= faces[entry.key];
    if (card == null) {
      throw FormatException('개별 카드 식별자가 일치하지 않습니다: ${entry.value}');
    }
    final complete = <String, dynamic>{
      ...card,
      if (facePrints.containsKey(entry.key))
        'editions': facePrints[entry.key]!.values.toList(),
    };
    stage.transaction(() => insert(complete));
    report('인덱스 대조 · ${seen.length} / ${index.length}장');
  }
}

const fullThreshold = .30;

Future<Map<String, String>> readIndex(OfficialApi api) async {
  final raw = await api.read('/cards/all');
  final index = SplayTreeMap<String, String>();
  if (raw is! List || raw.isEmpty) {
    throw const SyncProblem('index_mismatch', '공식 인덱스가 비어 있습니다.');
  }
  for (final row in raw) {
    if (row is! Json ||
        row['uuid'] is! String ||
        row['slug'] is! String ||
        (row['uuid'] as String).isEmpty ||
        (row['slug'] as String).isEmpty ||
        index.containsKey(row['uuid'])) {
      throw const SyncProblem('index_mismatch', '공식 인덱스 식별자가 잘못되거나 중복되었습니다.');
    }
    index[row['uuid']] = row['slug'];
  }
  return index;
}

String indexDigest(Map<String, String> index) =>
    sha256.convert(utf8.encode(jsonEncode(SplayTreeMap.of(index)))).toString();

Future<Map<String, Json>> changedPages(
  OfficialApi api,
  String filter,
  String date,
  void Function(SyncPhase, int, int?) progress,
) async {
  final found = <String, Json>{};
  int? pages;
  for (var page = 1; ; page++) {
    final data = await api.read('/cards/search', {
      filter: date,
      'page': '$page',
      'page_size': '50',
      'sort': 'name',
    });
    if (data is! Json ||
        data['data'] is! List ||
        data['total_pages'] is! int ||
        data['page'] != page) {
      throw const SyncProblem('pagination_mismatch', '변경 목록의 페이지 정보가 다릅니다.');
    }
    final rows = data['data'] as List;
    pages ??= data['total_pages'] as int;
    validatePage(data, page, pages, rows);
    if (pages == 0 && rows.isEmpty && page == 1) return found;
    if (data['total_pages'] != pages ||
        pages < page ||
        rows.length > 50 ||
        (rows.isEmpty && !(page == 1 && pages == 1))) {
      throw const SyncProblem('pagination_mismatch', '변경 목록이 수집 중 바뀌었습니다.');
    }
    for (final row in rows) {
      if (row is! Json ||
          row['uuid'] is! String ||
          found.containsKey(row['uuid'])) {
        throw const SyncProblem(
          'pagination_mismatch',
          '변경 목록에 중복 또는 빈 식별자가 있습니다.',
        );
      }
      found[row['uuid']] = row;
    }
    progress(
      filter == 'last_update'
          ? SyncPhase.fetching_card_changes
          : SyncPhase.fetching_edition_changes,
      page,
      pages,
    );
    if (page == pages) return found;
  }
}

typedef SyncProgress = void Function(SyncPhase, int, int?);
typedef SyncFinish = void Function(SyncCounts, bool, int);

Future<void> synchronize(
  Catalog live,
  Catalog stage,
  String stagePath,
  OfficialApi api,
  SyncMode mode,
  String started,
  SyncProgress progress,
  SyncFinish finish, {
  void Function()? beforeApply,
}) async {
  progress(SyncPhase.checking, 0, null);
  final health = live.inspect(resolveSpoilers: false);
  final state = live.baseline;
  final safeSince =
      live.metadata('syncSafeSince') ??
      state?['last_successful_sync'] as String?;
  var full =
      mode != SyncMode.incremental ||
      state == null ||
      !health.hasManifest ||
      health.damaged + health.missing > 0;
  final known = {
    for (final r in live.db.select('SELECT id,slug FROM sync_index'))
      r['id'] as String: r['slug'] as String,
  };
  if (state != null && indexDigest(known) != state['index_hash']) full = true;
  for (var attempt = 0; attempt < 2; attempt++) {
    stage.db.execute(
      'DELETE FROM tags; DELETE FROM editions; DELETE FROM cards;',
    );
    progress(SyncPhase.fetching_index, 0, null);
    final index = await readIndex(api);
    final digest = indexDigest(index);
    await api.indexReady(digest, safeSince);
    final active =
        live.db
                .select('SELECT count(*) n FROM cards WHERE active=1')
                .single['n']
            as int;
    if (index.length < active * (1 - fullThreshold) ||
        index.length < known.length * (1 - fullThreshold)) {
      throw const SyncProblem(
        'index_mismatch',
        '공식 카드 목록이 급격히 줄었습니다. 기존 데이터를 유지합니다.',
      );
    }
    if (known.keys.any((id) => !index.containsKey(id))) full = true;
    if (!full) {
      try {
        final date = DateTime.parse(safeSince!)
            .toUtc()
            .subtract(const Duration(days: 2))
            .toIso8601String()
            .substring(0, 10);
        final cards = await changedPages(api, 'last_update', date, progress);
        final editions = await changedPages(
          api,
          'edition_last_update',
          date,
          progress,
        );
        final ids = {
          ...cards.keys,
          ...editions.keys,
          for (final id in index.keys)
            if (index[id] != known[id]) id,
        };
        if (ids.length >= index.length * fullThreshold ||
            !ids.every(index.containsKey)) {
          full = true;
        } else {
          var done = 0;
          progress(SyncPhase.fetching_details, 0, ids.length);
          for (final id in ids) {
            final detail = await api.detail(
              '/cards/${index[id]}',
              editions[id] ?? cards[id],
            );
            if (detail is! Json ||
                detail['uuid'] != id ||
                detail['editions'] is! List) {
              throw const SyncProblem(
                'index_mismatch',
                '상세 카드 식별자가 일치하지 않습니다.',
              );
            }
            validateCard(detail);
            // The search groups backs under fronts. Only the full collector can
            // establish that other fronts don't contribute additional printings.
            final flip =
                live.db
                    .select(
                      """SELECT 1 FROM editions e,json_each(e.payload,'\$.other_orientations') o
              WHERE e.card=? OR json_extract(o.value,'\$.uuid')=? LIMIT 1""",
                      [id, id],
                    )
                    .isNotEmpty ||
                (detail['editions'] as List).any(
                  (e) => (e['other_orientations'] as List? ?? []).isNotEmpty,
                );
            if (flip) {
              full = true;
              break;
            }
            stage.transaction(() => stage.insert(detail));
            progress(SyncPhase.fetching_details, ++done, ids.length);
          }
        }
      } on SyncProblem catch (e) {
        if (e.transient) rethrow;
        full = true;
      } on FormatException {
        full = true;
      } on TypeError {
        full = true;
      }
    }
    if (full) {
      await api.beginFull();
      stage.db.execute(
        'DELETE FROM tags; DELETE FROM editions; DELETE FROM cards;',
      );
      await collect(
        stage,
        api,
        (_) {},
        indexAtStart: index,
        progress: progress,
      );
    }
    progress(SyncPhase.validating, 0, null);
    stage.recordManifest();
    final check = stage.inspect(resolveSpoilers: false);
    if (check.damaged + check.missing > 0) {
      throw const SyncProblem('invalid_response', '임시 카드 데이터 검증 실패');
    }
    if (indexDigest(await readIndex(api)) != digest) {
      full = true;
      continue;
    }
    progress(SyncPhase.applying, 0, null);
    final clock = Stopwatch()..start();
    void commit(SyncCounts counts) {
      final health = live.inspect(resolveSpoilers: false);
      if (health.missing + health.damaged > 0) {
        throw const SyncProblem(
          'database_corrupt',
          '반영 검증 실패 · 기존 DB로 되돌렸습니다.',
        );
      }
      if (full || state?['index_hash'] != digest) {
        live.db.execute('DELETE FROM sync_index');
        final insert = live.db.prepare('INSERT INTO sync_index VALUES(?,?)');
        try {
          for (final e in index.entries) {
            insert.execute([e.key, e.value]);
          }
        } finally {
          insert.close();
        }
      }
      final finished = syncNow();
      live.setMetadata('syncSafeSince', started);
      live.db.execute('INSERT OR REPLACE INTO sync_state VALUES(1,?,?,?)', [
        finished,
        full ? finished : state?['last_full'],
        digest,
      ]);
      finish(counts, full, clock.elapsedMilliseconds);
    }

    beforeApply?.call();
    if (full) {
      late SyncCounts counts;
      live.publish(
        stagePath,
        beforeApply: () => counts = live.countIncoming(true),
        afterApply: () => commit(counts),
      );
    } else {
      live.publishIncremental(stagePath, commit);
    }
    return;
  }
  throw const SyncProblem('index_mismatch', '공식 목록이 작업 중 반복해서 변경되었습니다.');
}

String syncDirectory(String path, String id) => '$path.sync-$id';
void discardScratch(String path, String id) {
  final dir = Directory(syncDirectory(path, id));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

Future<void> cancelSync(String path, Catalog live, String id) async {
  live.transaction(
    () => live.endSync(
      id,
      SyncStatus.cancelled,
      code: 'cancelled',
      message: '사용자가 취소했습니다.',
    ),
  );
  final lock = await SyncLock.acquire(path);
  if (lock != null) {
    try {
      discardScratch(path, id);
    } finally {
      await lock.close();
    }
  }
}

Future<void> updateCatalog(
  String path,
  void Function(String) report, {
  http.Client? client,
  SyncMode? mode,
  String? jobId,
}) async {
  final lock = await SyncLock.acquire(path);
  if (lock == null) return;
  final httpClient = client ?? http.Client();
  try {
    final live = Catalog(sqlite3.open(path));
    try {
      final id =
          jobId ??
          live.queueSync(
            mode ??
                (live.updated == null
                    ? SyncMode.initial
                    : SyncMode.incremental),
          );
      final job = live.job(id);
      if (job == null || live.pendingJob?['id'] != id) return;
      final requested = SyncMode.values.byName(job['mode'] as String);
      final directory = Directory(syncDirectory(path, id));
      final file = '${directory.path}/stage.sqlite';
      Catalog openStage() {
        directory.createSync(recursive: true);
        final db = sqlite3.open(file);
        try {
          if (db.select('PRAGMA quick_check').single.values.first != 'ok') {
            throw const FormatException('임시 DB 손상');
          }
          return Catalog(db);
        } catch (_) {
          db.close();
          rethrow;
        }
      }

      CheckpointApi? api;
      try {
        late Catalog stage;
        try {
          stage = openStage();
        } on SqliteException {
          discardScratch(path, id);
          stage = openStage();
        } on FormatException {
          discardScratch(path, id);
          stage = openStage();
        }
        try {
          api = CheckpointApi(
            httpClient,
            live,
            stage.db,
            id,
            file,
            job['started_at'] as String,
            requested,
          );
          final transport = api;
          await synchronize(
            live,
            stage,
            file,
            transport,
            requested,
            job['started_at'] as String,
            (phase, n, total) {
              transport.guard();
              live.progress(id, phase, n, total);
              report('${phase.name} · $n / ${total ?? "?"}');
            },
            (counts, full, ms) {
              transport.guard();
              live.db.execute(
                '''UPDATE sync_jobs SET requests=requests+?,bytes=bytes+?,fallback=?,added_cards=?,
                changed_cards=?,added_editions=?,changed_editions=?,removed_cards=?,apply_ms=? WHERE id=?''',
                [
                  transport.requests,
                  transport.bytes,
                  requested == SyncMode.incremental && full,
                  counts.addedCards,
                  counts.changedCards,
                  counts.addedEditions,
                  counts.changedEditions,
                  counts.removedCards,
                  ms,
                  id,
                ],
              );
              live.endSync(id, SyncStatus.completed);
            },
            beforeApply: transport.guard,
          );
        } finally {
          stage.db.close();
        }
      } catch (e) {
        final problem = classifySyncError(e);
        final paused = problem.transient;
        live.transaction(() {
          live.db.execute(
            'UPDATE sync_jobs SET requests=requests+?,bytes=bytes+? WHERE id=?',
            [api?.requests ?? 0, api?.bytes ?? 0, id],
          );
          live.endSync(
            id,
            paused ? SyncStatus.paused : SyncStatus.failed,
            code: problem.code,
            message: problem.message,
          );
        });
        if (e is! SyncCancelled) rethrow;
      } finally {
        if (live.pendingJob?['id'] != id) discardScratch(path, id);
      }
    } finally {
      live.db.close();
    }
  } finally {
    if (client == null) httpClient.close();
    await lock.close();
  }
}
