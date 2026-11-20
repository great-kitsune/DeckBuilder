import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

Future<Directory> imageDirectory() async =>
    Directory('${(await getApplicationCacheDirectory()).path}/card_images');

Future<int> cacheBytes() async {
  final dir = await imageDirectory();
  var size = 0;
  if (await dir.exists()) {
    await for (final entry in dir.list()) {
      if (entry is File) size += await entry.length();
    }
  }
  return size;
}

Future<void> clearCardImages() async {
  final dir = await imageDirectory();
  if (await dir.exists()) await dir.delete(recursive: true);
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
  late Future<File> image = load();
  Future<File> load() async {
    final path = widget.path;
    final key = sha256.convert(utf8.encode('$path|${widget.version}'));
    final dir = await imageDirectory();
    final cached = File('${dir.path}/$key');
    if (await cached.exists()) return cached;
    final response = await http
        .get(Uri.https('api.gatcg.com', path))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    await dir.create(recursive: true);
    final temp = File(
      '${cached.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsBytes(response.bodyBytes);
      return await temp.rename(cached.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<File>(
    future: image,
    builder: (context, snap) {
      if (snap.hasError) {
        if (widget.thumbnail) {
          return const Icon(Icons.image_not_supported_outlined);
        }
        return TextButton(
          onPressed: () => setState(() => image = load()),
          child: const Text('이미지 다시 불러오기'),
        );
      }
      if (!snap.hasData) {
        return const SizedBox(
          height: 60,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.file(
        snap.data!,
        height: widget.thumbnail ? null : 260,
        cacheWidth: widget.thumbnail ? 260 : null,
        errorBuilder: (_, _, _) => const Text('이미지를 읽을 수 없습니다.'),
      );
    },
  );
}
