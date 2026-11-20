import 'dart:io';
import 'offline_images.dart';
import 'package:flutter/material.dart';
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
  final bool thumbnail, useOffline;
  const EditionImage(
    this.path,
    this.version, {
    this.thumbnail = false,
    required this.useOffline,
    super.key,
  });
  @override
  State<EditionImage> createState() => _EditionImageState();
}

class _EditionImageState extends State<EditionImage> {
  late Future<File?> installed = findInstalled();
  int attempt = 0;

  @override
  void didUpdateWidget(EditionImage old) {
    super.didUpdateWidget(old);
    if (widget.path != old.path ||
        widget.version != old.version ||
        widget.useOffline != old.useOffline) {
      installed = findInstalled();
    }
  }

  Future<File?> findInstalled() async {
    if (!widget.useOffline) return null;
    final path = widget.path, version = widget.version;
    final directory = offlineImageDirectory(
      await getApplicationSupportDirectory(),
    );
    final file = imageFile(directory, path, version);
    return await file.exists() ? file : null;
  }

  Widget remoteImage() => Image.network(
    Uri.https(
      'api.gatcg.com',
      widget.path,
      widget.version.isEmpty ? null : {'v': widget.version},
    ).toString(),
    key: ValueKey(attempt),
    height: widget.thumbnail ? null : 260,
    cacheWidth: widget.thumbnail ? 260 : null,
    errorBuilder: (_, _, _) => widget.thumbnail
        ? const Icon(Icons.image_not_supported_outlined)
        : TextButton(
            onPressed: () => setState(() {
              attempt++;
              installed = findInstalled();
            }),
            child: const Text('이미지 다시 불러오기'),
          ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.useOffline) return remoteImage();
    return FutureBuilder<File?>(
      future: installed,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 60,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.data == null) return remoteImage();
        return Image.file(
          snap.data!,
          height: widget.thumbnail ? null : 260,
          cacheWidth: widget.thumbnail ? 260 : null,
          errorBuilder: (_, _, _) => remoteImage(),
        );
      },
    );
  }
}
