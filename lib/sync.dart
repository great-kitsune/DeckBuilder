import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'catalog.dart';

class OfficialApi {
  final http.Client client;
  OfficialApi(this.client);

  Future<dynamic> read(String path, [Map<String, String>? query]) async {
    final uri = Uri.https('api.gatcg.com', path, query);
    for (var attempt = 0; ; attempt++) {
      try {
        final response = await client
            .get(uri)
            .timeout(const Duration(seconds: 40));
        if (response.statusCode == 200) {
          return jsonDecode(utf8.decode(response.bodyBytes));
        }
        if (response.statusCode == 429 || response.statusCode >= 500) {
          throw HttpException(
            '서버가 응답하지 않습니다 (HTTP ${response.statusCode})',
            uri: uri,
          );
        }
        throw FormatException('카드 API 오류 (HTTP ${response.statusCode})');
      } on Exception catch (e) {
        if (e is FormatException || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }
}

Future<void> collect(
  Catalog stage,
  OfficialApi api,
  void Function(String) report,
) async {
  final index = await api.read('/cards/all') as List;
  final missing = <String, String>{
    for (final c in index) c['uuid'] as String: c['slug'] as String,
  };
  if (index.isEmpty || missing.length != index.length) {
    throw const FormatException('카드 인덱스가 비어 있거나 중복되었습니다.');
  }
  final seen = <String>{};
  void insert(Json card) {
    final id = card['uuid'] as String;
    if (!missing.containsKey(id) || !seen.add(id)) {
      throw FormatException('카드 인덱스 불일치: $id');
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
        faces[id] = face..remove('edition_id');
        (facePrints[id] ??= {})[edition['uuid'] as String] = edition;
      }
    }
  }

  int? totalPages;
  for (var page = 1; ; page++) {
    final result =
        await api.read('/cards/search', {
              'page': '$page',
              'page_size': '50',
              'sort': 'name',
            })
            as Json;
    totalPages ??= result['total_pages'] as int;
    final rows = result['data'] as List;
    if (result['page'] != page ||
        result['total_pages'] != totalPages ||
        totalPages < page ||
        rows.isEmpty) {
      throw const FormatException('카드 페이지가 누락되거나 수집 중 변경되었습니다.');
    }
    stage.transaction(() {
      for (final c in rows.cast<Json>()) {
        insert(c);
        collectFaces(c);
      }
    });
    report('$page / $totalPages 페이지 · ${seen.length} / ${index.length}장');
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

Future<void> updateCatalog(String path, void Function(String) report) async {
  final lock = await File('$path.sync-lock').open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
    final scratch = File('$path.incoming');
    final client = http.Client();
    try {
      // SQLite rolls back interrupted writes when opening the staging database.
      final stage = Catalog(sqlite3.open(scratch.path));
      try {
        stage.transaction(() {
          stage.db.execute(
            'DELETE FROM tags; DELETE FROM editions; DELETE FROM cards;',
          );
        });
        await collect(stage, OfficialApi(client), report);
      } finally {
        stage.db.close();
      }
      report('검증 완료 · 적용 중');
      final current = Catalog(sqlite3.open(path));
      try {
        current.publish(scratch.path);
      } finally {
        current.db.close();
      }
    } finally {
      client.close();
      if (await scratch.exists()) await scratch.delete();
    }
  } finally {
    await lock.close();
  }
}
