import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';
import 'catalog.dart';
import 'api_request.dart';

class OfficialApi {
  final http.Client client;
  OfficialApi(this.client);
  Future<dynamic> read(String path, [Map<String, String>? query]) async {
    final uri = Uri.https('api.gatcg.com', path, query);
    final response = await getFromApi(client, uri);
    return jsonDecode(utf8.decode(response.bodyBytes));
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

  Future<dynamic> pageData(int page) => api.read('/cards/search', {
    'page': '$page',
    'page_size': '50',
    'sort': 'name',
  });
  int? totalPages;
  var nextPage = pageData(1);
  for (var page = 1; ; page++) {
    final result = await nextPage as Json;
    totalPages ??= result['total_pages'] as int;
    final rows = result['data'] as List;
    if (result['page'] != page ||
        result['total_pages'] != totalPages ||
        totalPages < page ||
        rows.isEmpty) {
      throw const FormatException('카드 페이지가 누락되거나 수집 중 변경되었습니다.');
    }
    if (page < totalPages) {
      nextPage = pageData(page + 1);
      // The current page may fail validation before the next await.
      nextPage.ignore();
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

Future<void> updateCatalog(
  String path,
  void Function(String) report, {
  http.Client? client,
}) async {
  final lock = await File('$path.sync-lock').open(mode: FileMode.append);
  final httpClient = client ?? http.Client();
  try {
    await lock.lock(FileLock.exclusive);
    final catalog = Catalog(sqlite3.open(path));
    try {
      final scratch = File('$path.incoming');
      try {
        final stage = Catalog(sqlite3.open(scratch.path));
        try {
          stage.transaction(
            () => stage.db.execute(
              'DELETE FROM tags; DELETE FROM editions; DELETE FROM cards;',
            ),
          );
          await collect(stage, OfficialApi(httpClient), report);
        } finally {
          stage.db.close();
        }
        report('텍스트 DB 검증 완료 · 적용 중');
        catalog.publish(scratch.path);
      } finally {
        if (await scratch.exists()) await scratch.delete();
      }
    } finally {
      catalog.db.close();
    }
  } finally {
    if (client == null) httpClient.close();
    await lock.close();
  }
}
