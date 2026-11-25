import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'theme_repository.dart';

class ThemeBackground extends StatelessWidget {
  final SelectedGraphic graphic;
  const ThemeBackground(this.graphic, {super.key});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final preferred = ThemeArt.forWindow(size.width, size.height);
    final art = graphic.files.containsKey(preferred)
        ? preferred
        : graphic.primary;
    return _Artwork(key: ValueKey((graphic, art)), graphic: graphic, art: art);
  }
}

class _Artwork extends StatefulWidget {
  final SelectedGraphic graphic;
  final ThemeArt art;
  const _Artwork({
    required super.key,
    required this.graphic,
    required this.art,
  });
  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  late final cached = widget.graphic.cached(widget.art);
  late final download = cached == null
      ? widget.graphic.loadVariant(widget.art)
      : null;

  Widget image(Uint8List bytes, ThemeArt art) => Image.memory(
    bytes,
    fit: BoxFit.cover,
    cacheWidth: 800,
    alignment: art == ThemeArt.wide ? Alignment.centerRight : Alignment.center,
    excludeFromSemantics: true,
    errorBuilder: (context, _, _) =>
        ColoredBox(color: Theme.of(context).colorScheme.surface),
  );

  @override
  Widget build(BuildContext context) {
    if (cached != null) return image(cached!, widget.art);
    return FutureBuilder<Uint8List>(
      future: download,
      builder: (_, snapshot) => snapshot.hasData
          ? image(snapshot.requireData, widget.art)
          : image(widget.graphic.image, widget.graphic.primary),
    );
  }
}
