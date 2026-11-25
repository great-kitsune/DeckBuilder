import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api_request.dart';
import 'catalog.dart';

Future<List<Directory>> _directories() async => [
  Directory('${(await getApplicationCacheDirectory()).path}/card_images'),
  // Previous full installs used the same versioned keys in app support.
  Directory('${(await getApplicationSupportDirectory()).path}/catalog-images'),
];

Stream<File> _files([List<Directory>? directories]) async* {
  for (final dir in directories ?? await _directories()) {
    if (await dir.exists()) {
      await for (final file in dir.list(followLinks: false)) {
        if (file is File &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(file.uri.pathSegments.last)) {
          yield file;
        }
      }
    }
  }
}

Future<int> cacheBytes() async {
  var bytes = 0;
  await for (final file in _files()) {
    bytes += await file.length();
  }
  return bytes;
}

Future<void> clearCardImages() async {
  await for (final file in _files()) {
    if (await file.exists()) await file.delete();
  }
}

Future<bool> decodableImage(Uint8List data) async {
  try {
    final codec = await ui.instantiateImageCodec(data, targetWidth: 1);
    try {
      (await codec.getNextFrame()).image.dispose();
    } finally {
      codec.dispose();
    }
    return true;
  } on Exception {
    return false;
  }
}

final _loading = <String, Future<Uint8List>>{};
final _inspecting = <String, Future<bool>>{};

Future<int> removeDamagedImages({List<Directory>? directories}) async {
  var damaged = 0;
  await for (final file in _files(directories)) {
    final key = file.uri.pathSegments.last;
    // A view already reading this version performs the same decode check.
    if (_loading.containsKey(key)) continue;
    final check = _inspecting.putIfAbsent(key, () async {
      try {
        if (await decodableImage(await file.readAsBytes())) return false;
        await file.delete();
        return true;
      } on PathNotFoundException {
        return false;
      } finally {
        _inspecting.remove(key);
      }
    });
    if (await check) damaged++;
  }
  return damaged;
}

Future<Uint8List> viewedImage(
  String path,
  String version, {
  List<Directory>? directories,
  http.Client? client,
}) {
  final key = sha256.convert(utf8.encode('$path|$version')).toString();
  return _loading.putIfAbsent(key, () async {
    try {
      await _inspecting[key];
      final dirs = directories ?? await _directories();
      for (final dir in dirs) {
        final file = File('${dir.path}/$key');
        try {
          final bytes = await file.readAsBytes();
          if (await decodableImage(bytes)) return bytes;
          await file.delete();
        } on PathNotFoundException {
          continue;
        }
      }
      final api = client ?? http.Client();
      try {
        final uri = Uri.https(
          'api.gatcg.com',
          path,
          version.isEmpty ? null : {'v': version},
        );
        final response = await getFromApi(api, uri);
        final bytes = response.bodyBytes;
        if (!await decodableImage(bytes)) {
          throw const FormatException('공식 이미지 파일을 읽을 수 없습니다.');
        }
        final target = File('${dirs.first.path}/$key');
        final temp = File(
          '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.part',
        );
        try {
          await dirs.first.create(recursive: true);
          await temp.writeAsBytes(bytes, flush: true);
          await temp.rename(target.path);
        } on FileSystemException {
          // A full or read-only cache must not prevent viewing the response.
        } finally {
          if (await temp.exists()) await temp.delete();
        }
        return bytes;
      } finally {
        if (client == null) api.close();
      }
    } finally {
      _loading.remove(key);
    }
  });
}

class EditionImage extends StatefulWidget {
  final String path, version;
  final bool thumbnail;
  const EditionImage(
    this.path,
    this.version, {
    this.thumbnail = false,
    super.key,
  });
  @override
  State<EditionImage> createState() => _EditionImageState();
}

class _EditionImageState extends State<EditionImage> {
  late Future<Uint8List> image = viewedImage(widget.path, widget.version);

  @override
  void didUpdateWidget(EditionImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.version != widget.version) {
      image = viewedImage(widget.path, widget.version);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: image,
    builder: (context, snap) {
      if (snap.connectionState == ConnectionState.done && snap.hasError) {
        return widget.thumbnail
            ? const Icon(Icons.image_not_supported_outlined)
            : TextButton(
                onPressed: () => setState(
                  () => image = viewedImage(widget.path, widget.version),
                ),
                child: const Text('이미지 다시 불러오기'),
              );
      }
      if (snap.connectionState != ConnectionState.done || !snap.hasData) {
        return const SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.memory(
        snap.data!,
        height: widget.thumbnail ? null : 260,
        cacheWidth: widget.thumbnail ? 260 : null,
      );
    },
  );
}

typedef CardArt = ({Uint8List? local, String? path, String version});

CardArt catalogArt(
  Catalog catalog,
  String id,
  String? edition, {
  required bool spoiler,
}) {
  final local = spoiler
      ? (catalog.db.select('SELECT photo FROM spoiler_cards WHERE id=?', [
              id,
            ]).firstOrNull?['photo']
            as Uint8List?)
      : null;
  var print = catalog.db
      .select(
        """SELECT json_extract(payload,'\$.image') image,
      json_extract(payload,'\$.last_update') version FROM library_editions WHERE card=? AND (? IS NULL OR id=?) ORDER BY position,id LIMIT 1""",
        [id, edition, edition],
      )
      .firstOrNull;
  if (print == null && edition != null) {
    print = catalog.db
        .select(
          """SELECT json_extract(payload,'\$.image') image,
        json_extract(payload,'\$.last_update') version FROM retired_editions WHERE card=? AND id=?""",
          [id, edition],
        )
        .firstOrNull;
  }
  final path = print?['image'] as String?;
  return (
    local: local,
    path: path != null && path.startsWith('/cards/images/') ? path : null,
    version: print?['version']?.toString() ?? '',
  );
}

class CatalogThumbnail extends StatelessWidget {
  final Catalog catalog;
  final String id;
  final String? edition;
  final bool spoiler;
  final int revision;
  const CatalogThumbnail(
    this.catalog,
    this.id,
    this.edition, {
    required this.spoiler,
    required this.revision,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final (:local, :path, :version) = catalogArt(
      catalog,
      id,
      edition,
      spoiler: spoiler,
    );
    const fallback = Icon(Icons.image_outlined);
    return local != null
        ? Image.memory(
            local,
            cacheWidth: 260,
            errorBuilder: (_, _, _) => fallback,
          )
        : path != null
        ? EditionImage(
            path,
            version,
            thumbnail: true,
            key: ValueKey((path, version, revision)),
          )
        : fallback;
  }
}
