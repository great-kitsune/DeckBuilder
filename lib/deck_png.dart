import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/painting.dart';
import 'catalog.dart';

/// Draw the full saved list, including rows outside the editor's viewport.
Future<Uint8List> renderDeckPng(String name, List<DeckEntry> entries) async {
  const width = 960;
  const margin = 40.0;
  const ink = Color(0xff163b3c);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xfffafaf6), BlendMode.src);
  var y = margin;
  void line(String value, double size, {bool heading = false}) {
    final text = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: ink,
          fontSize: size,
          fontWeight: heading ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width - margin * 2);
    text.paint(canvas, Offset(margin, y));
    y += text.height + 8;
    text.dispose();
  }

  line(name, 40, heading: true);
  for (final zone in DeckZone.values) {
    final cards = entries.where((e) => e.zone == zone);
    final count = cards.fold(0, (n, e) => n + e.quantity);
    final points = cards.fold(0, (n, e) => n + e.quantity * e.cost.points);
    y += 18;
    canvas.drawLine(
      Offset(margin, y),
      Offset(width - margin, y),
      Paint()..color = const Color(0xffa2b9ae),
    );
    y += 12;
    final total = zone == DeckZone.sideboard ? '$count장 · $points점' : '$count장';
    line('${zone.label} · $total', 29, heading: true);
    for (final e in cards) {
      line(
        [
          '${e.quantity} × ${e.name}',
          if (e.printing.isNotEmpty) e.printing,
          ?e.status,
        ].join('    ·    '),
        23,
      );
    }
  }
  final picture = recorder.endRecording();
  final height = (y + margin).ceil();
  try {
    if (height > 16384) {
      throw const FormatException('한 PNG로 저장하기에는 덱 목록이 너무 깁니다.');
    }
    final image = await picture.toImage(width, height);
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
}

Future<bool> saveDeckPng(String name, List<DeckEntry> entries) async {
  final bytes = await renderDeckPng(name, entries);
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
