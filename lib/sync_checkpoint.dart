part of 'sync.dart';

class SyncCancelled implements Exception {}

class CheckpointApi extends OfficialApi {
  final Catalog live;
  final Database cache;
  final String id, path, started;
  final SyncMode mode;
  bool prepared = false;
  int replayThrough = 0;
  CheckpointApi(
    super.client,
    this.live,
    this.cache,
    this.id,
    this.path,
    this.started,
    this.mode,
  ) {
    cache.execute(
      'CREATE TABLE IF NOT EXISTS responses(key TEXT PRIMARY KEY, body TEXT NOT NULL,digest TEXT NOT NULL)',
    );
  }
  @override
  void guard() {
    if (live.job(id)?['status'] == 'cancelled') throw SyncCancelled();
  }

  @override
  void beforeAttempt() {
    guard();
    live.db.execute('UPDATE sync_jobs SET requests=requests+1 WHERE id=?', [
      id,
    ]);
  }

  @override
  void received(int bytes) {
    live.db.execute('UPDATE sync_jobs SET bytes=bytes+? WHERE id=?', [
      bytes,
      id,
    ]);
  }

  @override
  Future<dynamic> read(String path, [Map<String, String>? query]) async {
    guard();
    if (path == '/cards/search' &&
        query != null &&
        !query.containsKey('last_update') &&
        !query.containsKey('edition_last_update')) {
      final page = int.parse(query['page']!);
      if (page <= replayThrough) {
        final saved = load('page:$page');
        if (saved != null) return saved;
      }
      final data = await super.read(path, query);
      guard();
      save('page:$page', data);
      return data;
    }
    return super.read(path, query);
  }

  dynamic load(String key) {
    final r = cache.select('SELECT body,digest FROM responses WHERE key=?', [
      key,
    ]).firstOrNull;
    if (r == null) return null;
    final body = r['body'] as String;
    if (sha256.convert(utf8.encode(body)).toString() != r['digest']) {
      return null;
    }
    return jsonDecode(body);
  }

  void save(String key, dynamic data) {
    final body = jsonEncode(data);
    cache.execute('INSERT OR REPLACE INTO responses VALUES(?,?,?)', [
      key,
      body,
      sha256.convert(utf8.encode(body)).toString(),
    ]);
  }

  @override
  Future<void> indexReady(String hash, String? baseline) async {
    final signature = jsonEncode([id, mode.name, started, baseline, hash]);
    if (load('signature') != signature) {
      cache.execute('DELETE FROM responses');
      save('signature', signature);
    }
    live.db.execute('UPDATE sync_jobs SET checkpoint=? WHERE id=?', [
      jsonEncode({
        'path': path,
        'index': hash,
        'mode': mode.name,
        'started': started,
        'baseline': baseline,
        'pageSize': 50,
        'sort': 'name',
      }),
      id,
    ]);
    replayThrough = 0;
    prepared = false;
  }

  @override
  Future<void> beginFull() async {
    if (mode == SyncMode.incremental) {
      live.db.execute('UPDATE sync_jobs SET fallback=1 WHERE id=?', [id]);
    }
    if (prepared) return;
    prepared = true;
    // Never resume at a blind page offset. Require a contiguous, intact prefix,
    // fresh change windows and an identical boundary page including page counts.
    var last = 0;
    while (load('page:${last + 1}') != null) {
      last++;
    }
    if (last == 0) return;
    final since = DateTime.parse(
      started,
    ).subtract(const Duration(days: 2)).toIso8601String().substring(0, 10);
    for (final filter in ['last_update', 'edition_last_update']) {
      if ((await changedPages(this, filter, since, (_, _, _) {})).isNotEmpty) {
        cache.execute("DELETE FROM responses WHERE key LIKE 'page:%'");
        return;
      }
    }
    guard();
    final boundary = await super.read('/cards/search', {
      'page': '$last',
      'page_size': '50',
      'sort': 'name',
    });
    if (jsonEncode(boundary) == jsonEncode(load('page:$last'))) {
      replayThrough = last;
    } else {
      cache.execute("DELETE FROM responses WHERE key LIKE 'page:%'");
    }
  }

  @override
  Future<dynamic> detail(String path, Json? candidate) async {
    guard();
    final saved = load('detail:$path');
    // A filtered/partial edition list cannot authenticate a cached detail.
    Json comparable(Json card) => Json.of(card)..remove('result_editions');
    if (saved is Json &&
        candidate != null &&
        jsonEncode(comparable(saved)) == jsonEncode(comparable(candidate))) {
      return saved;
    }
    final data = await super.detail(path, candidate);
    guard();
    save('detail:$path', data);
    return data;
  }
}
