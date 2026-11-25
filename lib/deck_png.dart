import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'card_image.dart';
import 'catalog.dart';

const _cardWidth = 248.0;
const _cardHeight = 348.0;
const _margin = 24.0;
const _gap = 14.0;
const _rowHeight = _cardHeight + 86;
const _ink = Color(0xff163b3c);

TextPainter _text(
  String value,
  double size,
  double width, {
  FontWeight weight = FontWeight.normal,
  Color color = _ink,
  int? lines,
}) => TextPainter(
  text: TextSpan(
    text: value,
    style: TextStyle(
      color: color,
      fontSize: size,
      fontFamilyFallback: const [
        'Malgun Gothic',
        'Noto Sans CJK KR',
        'sans-serif',
      ],
      fontWeight: weight,
      height: 1.15,
    ),
  ),
  textDirection: TextDirection.ltr,
  maxLines: lines,
  ellipsis: lines == null ? null : '…',
)..layout(maxWidth: width);

typedef ArtLoader = Future<Uint8List> Function(String path, String version);

Future<ui.Image?> _thumbnail(
  CardArt art,
  int pixelWidth,
  ArtLoader load,
) async {
  try {
    final bytes =
        art.local ??
        (art.path == null ? null : await load(art.path!, art.version));
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodecWithSize(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (w, h) {
        final scale = math.min(
          1.0,
          math.min(pixelWidth / w, pixelWidth * _cardHeight / _cardWidth / h),
        );
        return ui.TargetImageSize(
          width: math.max(1, (w * scale).round()),
          height: math.max(1, (h * scale).round()),
        );
      },
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } on Exception {
    return null;
  }
}

void _drawTile(Canvas canvas, Offset origin, DeckEntry entry, ui.Image? image) {
  final frame = origin & const Size(_cardWidth, _cardHeight);
  var face = frame;
  canvas.drawRRect(
    RRect.fromRectAndRadius(frame, const Radius.circular(8)),
    Paint()..color = const Color(0xffe4ebe6),
  );
  if (image != null) {
    final source = Size(image.width.toDouble(), image.height.toDouble());
    final fit = applyBoxFit(BoxFit.contain, source, frame.size);
    face = Alignment.center.inscribe(fit.destination, frame);
    canvas.drawImageRect(
      image,
      Offset.zero & source,
      face,
      Paint()..filterQuality = FilterQuality.medium,
    );
  } else {
    final name = _text(
      entry.name,
      23,
      _cardWidth - 32,
      weight: FontWeight.w600,
      lines: 4,
    );
    name.paint(canvas, frame.center - Offset(name.width / 2, name.height / 2));
    name.dispose();
  }

  final quantity = _text(
    '${entry.quantity}',
    29,
    _cardWidth - 16,
    weight: FontWeight.bold,
    color: const Color(0xffffffff),
  );
  final center = Offset(frame.center.dx, face.top + face.height * .82);
  final badge = Rect.fromCenter(
    center: center,
    width: math.max(54, quantity.width + 22),
    height: quantity.height + 12,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(badge, const Radius.circular(6)),
    Paint()..color = const Color(0xd9000000),
  );
  quantity.paint(
    canvas,
    center - Offset(quantity.width / 2, quantity.height / 2),
  );
  quantity.dispose();

  final title = _text(
    entry.name,
    17,
    _cardWidth,
    weight: FontWeight.w600,
    lines: 2,
  );
  title.paint(canvas, Offset(frame.left, frame.bottom + 5));
  final meta = [
    if (entry.printing.isNotEmpty) entry.printing,
    ?entry.status,
  ].join(' · ');
  if (meta.isNotEmpty) {
    final subtitle = _text(meta, 14, _cardWidth, lines: 2);
    subtitle.paint(canvas, Offset(frame.left, frame.bottom + 6 + title.height));
    subtitle.dispose();
  }
  title.dispose();
}

/// Render every saved entry once per zone and selected edition.
Future<Uint8List> renderDeckPng(
  Catalog catalog,
  String name,
  List<DeckEntry> entries, {
  ArtLoader load = viewedImage,
}) async {
  final sections = {
    for (final zone in DeckZone.values)
      zone: entries.where((e) => e.zone == zone).toList()
        ..sort(compareDeckEntries),
  };
  final columns = sections.values
      .map((cards) => cards.length)
      .reduce(math.max)
      .clamp(1, 5);
  final width = _margin * 2 + columns * _cardWidth + (columns - 1) * _gap;
  final title = _text(name, 32, width - 2 * _margin, weight: FontWeight.bold);
  double y = _margin + title.height + 16;
  final headers = <DeckZone, TextPainter>{};
  var height = y + _margin;
  for (final group in sections.entries) {
    final count = group.value.fold(0, (n, e) => n + e.quantity);
    final points = group.value.fold(
      0,
      (n, e) => n + e.quantity * e.cost.points,
    );
    final total = group.key == DeckZone.sideboard
        ? '$count장 · $points점'
        : '$count장';
    final header = _text(
      '${group.key.label} · $total',
      22,
      width - 2 * _margin,
      weight: FontWeight.bold,
    );
    headers[group.key] = header;
    height +=
        header.height + 24 + (group.value.length / columns).ceil() * _rowHeight;
  }
  // Keep large decks within the pixel budget of the mobile raster surface.
  final scale = math.min(
    1.0,
    math.min(16384 / height, math.sqrt(16000000 / (width * height))),
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(scale)
    ..drawColor(const Color(0xfffafaf6), BlendMode.src);
  try {
    title.paint(canvas, const Offset(_margin, _margin));
    for (final group in sections.entries) {
      canvas.drawLine(
        Offset(_margin, y),
        Offset(width - _margin, y),
        Paint()..color = const Color(0xffa2b9ae),
      );
      final header = headers[group.key]!;
      header.paint(canvas, Offset(_margin, y + 8));
      y += header.height + 24;
      for (var i = 0; i < group.value.length; i += columns) {
        final row = group.value.sublist(
          i,
          math.min(i + columns, group.value.length),
        );
        final sources = [
          for (final e in row)
            catalogArt(
              catalog,
              e.card,
              e.edition.isEmpty ? null : e.edition,
              spoiler: e.spoiler,
            ),
        ];
        final images = await Future.wait([
          for (final source in sources)
            _thumbnail(source, math.max(1, (_cardWidth * scale).ceil()), load),
        ]);
        try {
          for (final (column, entry) in row.indexed) {
            _drawTile(
              canvas,
              Offset(_margin + column * (_cardWidth + _gap), y),
              entry,
              images[column],
            );
          }
        } finally {
          for (final image in images) {
            image?.dispose();
          }
        }
        y += _rowHeight;
      }
    }
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(
        (width * scale).ceil(),
        (height * scale).ceil(),
      );
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw StateError('PNG 생성에 실패했습니다.');
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  } finally {
    if (recorder.isRecording) recorder.endRecording().dispose();
    title.dispose();
    for (final header in headers.values) {
      header.dispose();
    }
  }
}

Future<bool> saveDeckPng(String name, Uint8List bytes) async {
  final safe = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '덱 리스트 PNG 저장',
    fileName: 'Deck - ${String.fromCharCodes(safe.runes.take(80))}.png',
    type: FileType.custom,
    allowedExtensions: ['png'],
    bytes: bytes,
  );
  return path != null;
}
