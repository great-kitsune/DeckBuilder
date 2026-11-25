import 'dart:convert';
import 'dart:typed_data';
import 'catalog.dart';
import 'card_image.dart';

class GraphicTheme {
  final String card,
      name,
      edition,
      slug,
      setName,
      setCode,
      number,
      rarity,
      path,
      version;
  const GraphicTheme({
    required this.card,
    required this.name,
    required this.edition,
    required this.slug,
    required this.setName,
    required this.setCode,
    required this.number,
    required this.rarity,
    required this.path,
    required this.version,
  });

  String get printing => [
    if (setName.isNotEmpty) setName,
    if (setCode.isNotEmpty) setCode,
    if (number.isNotEmpty) '#$number',
    if (rarity.isNotEmpty) '희귀도 $rarity',
  ].join(' · ');
}

bool _allowed(String path, String edition) {
  if (!RegExp(r'^/[A-Za-z0-9/_ .-]+$').hasMatch(path) ||
      path.split('/').skip(1).any((s) => s.isEmpty || s == '.' || s == '..')) {
    return false;
  }
  return (path.startsWith('/cards/images/') &&
          path.toLowerCase().endsWith('.jpg')) ||
      path == '/graphics/editions/$edition/banner/tall.jpg';
}

List<GraphicTheme> graphicThemes(Catalog c, {String? editionId}) {
  final candidates = <GraphicTheme>[];
  for (final row in c.db.select(
    """
    SELECT c.name,e.id,e.card,e.set_code,e.number,e.rarity,
      json_extract(e.payload,'\$.graphics.banner') banner,
      json_extract(e.payload,'\$.slug') slug,json_extract(e.payload,'\$.set.name') set_name,
      json_extract(e.payload,'\$.last_update') version
    FROM editions e JOIN cards c ON c.id=e.card
    WHERE c.active=1 AND json_type(e.payload,'\$.graphics.banner')='array'
    AND (? IS NULL OR e.id=?) ORDER BY c.norm,e.position,e.id""",
    [editionId, editionId],
  )) {
    final id = row['id'] as String;
    final seen = <String>{};
    for (final item
        in (jsonDecode(row['banner'] as String) as List).whereType<Map>()) {
      final path = item['image'];
      if (path is! String || !_allowed(path, id) || !seen.add(path)) continue;
      final name = item['name']?.toString().toLowerCase();
      if (!path.endsWith('/tall.jpg') &&
          !const {'tall', 'tall.jpg', 'banner/tall.jpg'}.contains(name)) {
        continue;
      }
      candidates.add(
        GraphicTheme(
          card: row['card'] as String,
          name: row['name'] as String,
          edition: id,
          slug: row['slug']?.toString() ?? '',
          setName: row['set_name']?.toString() ?? '',
          setCode: row['set_code']?.toString() ?? '',
          number: row['number']?.toString() ?? '',
          rarity: row['rarity']?.toString() ?? '',
          path: path,
          version: (item['last_update'] ?? row['version'])?.toString() ?? '',
        ),
      );
    }
  }
  return candidates;
}

typedef SelectedGraphic = ({
  String edition,
  String path,
  String version,
  double overlay,
  Uint8List image,
});
const graphicSetting = 'graphicsTheme';

Future<SelectedGraphic?> readGraphicTheme(Catalog c) async {
  final raw = c.metadata(graphicSetting);
  if (raw == null) return null;
  try {
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['edition'] is! String ||
        data['path'] is! String ||
        data['version'] is! String ||
        data['image'] is! String ||
        data['overlay'] is! num ||
        !_allowed(data['path'], data['edition'])) {
      return null;
    }
    final image = base64Decode(data['image']);
    if (!await decodableImage(image)) return null;
    return (
      edition: data['edition'] as String,
      path: data['path'] as String,
      version: data['version'] as String,
      overlay: (data['overlay'] as num).clamp(0, 1).toDouble(),
      image: image,
    );
  } on FormatException {
    return null;
  }
}

Future<SelectedGraphic> selectGraphicTheme(
  Catalog c,
  GraphicTheme choice, {
  Future<Uint8List> Function(String, String) load = viewedImage,
}) async {
  bool available() => graphicThemes(
    c,
    editionId: choice.edition,
  ).any((g) => g.path == choice.path && g.version == choice.version);
  if (!available()) throw const FormatException('테마 목록이 변경되었습니다.');
  final bytes = await load(choice.path, choice.version);
  if (!await decodableImage(bytes)) {
    throw const FormatException('이미지를 읽을 수 없습니다.');
  }
  if (!available()) throw const FormatException('다운로드 중 테마 정보가 변경되었습니다.');
  const overlay = .60;
  c.setMetadata(
    graphicSetting,
    jsonEncode({
      'edition': choice.edition,
      'path': choice.path,
      'version': choice.version,
      'overlay': overlay,
      'image': base64Encode(bytes),
    }),
  );
  return (
    edition: choice.edition,
    path: choice.path,
    version: choice.version,
    overlay: overlay,
    image: bytes,
  );
}

void resetGraphicTheme(Catalog c) =>
    c.db.execute('DELETE FROM metadata WHERE key=?', [graphicSetting]);
