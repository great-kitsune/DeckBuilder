import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'catalog.dart';
import 'api_request.dart';

File imageFile(Directory directory, String path, String version) {
  final key = sha256.convert(utf8.encode('$path|$version'));
  return File('${directory.path}/$key');
}

Directory offlineImageDirectory(Directory appDirectory) =>
    Directory('${appDirectory.path}/catalog-images');

Future<void> installImages(
  Catalog catalog,
  Directory directory,
  http.Client client,
  void Function(String) report,
) async {
  final rows = catalog.db.select("""
    SELECT DISTINCT json_extract(e.payload,'\$.image') AS path,
      coalesce(json_extract(e.payload,'\$.last_update'),'') AS version
    FROM editions e JOIN cards c ON e.card=c.id
    WHERE c.active=1 AND c.spoiler=0 AND json_extract(e.payload,'\$.image') IS NOT NULL
    ORDER BY path,version
  """);
  await directory.create(recursive: true);
  final currentFiles = <String>{};
  var completed = 0;
  for (final row in rows) {
    final path = row['path'] as String;
    if (!path.startsWith('/cards/images/')) {
      throw FormatException('지원하지 않는 카드 이미지 경로: $path');
    }
    final file = imageFile(directory, path, row['version'] as String);
    currentFiles.add(file.uri.pathSegments.last);
    if (!await file.exists() || await file.length() == 0) {
      await _downloadImage(client, path, file);
    }
    completed++;
    if (completed == 1 || completed % 10 == 0 || completed == rows.length) {
      report('이미지 설치 · $completed / ${rows.length}개');
    }
  }
  // Only discard superseded versions once the current snapshot is complete.
  await for (final entry in directory.list()) {
    if (entry is File && !currentFiles.contains(entry.uri.pathSegments.last)) {
      await entry.delete();
    }
  }
}

Future<void> _downloadImage(
  http.Client client,
  String path,
  File destination,
) async {
  final uri = Uri.https('api.gatcg.com', path);
  final response = await getFromApi(client, uri);
  final data = response.bodyBytes;
  if (data.isEmpty ||
      !(response.headers['content-type'] ?? '').toLowerCase().startsWith(
        'image/',
      )) {
    throw HttpException('이미지 파일을 읽을 수 없습니다', uri: uri);
  }
  final temp = File('${destination.path}.part');
  try {
    await temp.writeAsBytes(data, flush: true);
    await temp.rename(destination.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}
