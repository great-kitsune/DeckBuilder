import 'dart:convert';
import 'dart:typed_data';
import 'catalog.dart';
import 'card_image.dart';

enum ThemeArt {
  tall('banner', 'tall'),
  large('icon', 'large'),
  wide('banner', 'wide');

  final String group, file;
  const ThemeArt(this.group, this.file);

  static ThemeArt forWindow(double width, double height) {
    if (width * 1.5 < height) return tall;
    if (height * 1.5 < width) return wide;
    return large;
  }

  bool allows(String path, String edition) {
    if (!RegExp(r'^/[A-Za-z0-9/_ .-]+$').hasMatch(path) ||
        path
            .split('/')
            .skip(1)
            .any((s) => s.isEmpty || s == '.' || s == '..')) {
      return false;
    }
    return (path.startsWith('/cards/images/') &&
            path.toLowerCase().endsWith('.jpg')) ||
        path == '/graphics/editions/$edition/$group/$file.jpg';
  }
}

typedef GraphicFile = ({String path, String version});
typedef GraphicLoader = Future<Uint8List> Function(String, String);

class GraphicTheme {
  final String card, name, edition, slug, setName, setCode, number, rarity;
  final Map<ThemeArt, GraphicFile> files;
  const GraphicTheme({
    required this.card,
    required this.name,
    required this.edition,
    required this.slug,
    required this.setName,
    required this.setCode,
    required this.number,
    required this.rarity,
    required this.files,
  });

  ThemeArt get primary => files.keys.first;
  String get path => files[primary]!.path;
  String get version => files[primary]!.version;
  String get printing => [
    if (setName.isNotEmpty) setName,
    if (setCode.isNotEmpty) setCode,
    if (number.isNotEmpty) '#$number',
    if (rarity.isNotEmpty) '희귀도 $rarity',
  ].join(' · ');
}

List<GraphicTheme> graphicThemes(Catalog c, {String? editionId}) {
  final candidates = <GraphicTheme>[];
  for (final row in c.db.select(
    """
    SELECT c.name,e.id,e.card,e.set_code,e.number,e.rarity,
      json_extract(e.payload,'\$.graphics') graphics,
      json_extract(e.payload,'\$.slug') slug,json_extract(e.payload,'\$.set.name') set_name,
      json_extract(e.payload,'\$.last_update') version
    FROM editions e JOIN cards c ON c.id=e.card
    WHERE c.active=1 AND json_type(e.payload,'\$.graphics')='object'
    AND (? IS NULL OR e.id=?) ORDER BY c.norm,e.position,e.id""",
    [editionId, editionId],
  )) {
    final id = row['id'] as String;
    final graphics = jsonDecode(row['graphics'] as String) as Map;
    final files = <ThemeArt, GraphicFile>{};
    for (final art in ThemeArt.values) {
      final items = graphics[art.group];
      if (items is! List) continue;
      for (final item in items.whereType<Map>()) {
        final path = item['image'];
        if (path is! String || !art.allows(path, id)) continue;
        final name = item['name']?.toString().toLowerCase();
        if (!path.endsWith('/${art.file}.jpg') &&
            !{
              art.file,
              '${art.file}.jpg',
              '${art.group}/${art.file}.jpg',
            }.contains(name)) {
          continue;
        }
        files[art] = (
          path: path,
          version: (item['last_update'] ?? row['version'])?.toString() ?? '',
        );
        break;
      }
    }
    if (files.isEmpty) continue;
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
        files: files,
      ),
    );
  }
  return candidates;
}

const graphicSetting = 'graphicsTheme';

class SelectedGraphic {
  final String edition;
  final ThemeArt primary;
  final double overlay;
  final Map<ThemeArt, GraphicFile> files;
  final Uint8List image;
  final Map<ThemeArt, Uint8List> _images;
  final Catalog _catalog;
  final GraphicLoader _load;

  SelectedGraphic._(
    this._catalog,
    this.edition,
    this.primary,
    this.overlay,
    this.files,
    this.image,
    this._images,
    this._load,
  );
  String get path => files[primary]!.path;
  String get version => files[primary]!.version;

  Map<String, dynamic> _encode() => {
    'edition': edition,
    'primary': primary.name,
    'path': path,
    'version': version,
    'overlay': overlay,
    'image': base64Encode(image),
    'variants': {
      for (final entry in files.entries)
        if (entry.key != primary)
          entry.key.name: {
            'path': entry.value.path,
            'version': entry.value.version,
          },
    },
  };

  Uint8List? cached(ThemeArt art) => art == primary ? image : _images[art];

  Future<Uint8List> loadVariant(ThemeArt art) async {
    final source = files[art]!;
    final bytes = await _load(source.path, source.version);
    if (!await decodableImage(bytes)) {
      throw const FormatException('테마 이미지를 읽을 수 없습니다.');
    }
    _images[art] = bytes;
    // A resize can finish downloading after a different theme or backup is selected.
    final raw = _catalog.metadata(graphicSetting);
    if (raw == null) return bytes;
    final saved = jsonDecode(raw);
    if (saved is! Map ||
        saved['edition'] != edition ||
        saved['path'] != path ||
        saved['version'] != version ||
        saved['image'] != base64Encode(image)) {
      return bytes;
    }
    final variants = saved['variants'] is Map
        ? Map<String, dynamic>.from(saved['variants'])
        : <String, dynamic>{};
    final stored = variants[art.name];
    if (stored is Map &&
        (stored['path'] != source.path ||
            stored['version'] != source.version)) {
      return bytes;
    }
    variants[art.name] = {
      'path': source.path,
      'version': source.version,
      'image': base64Encode(bytes),
    };
    saved['variants'] = variants;
    _catalog.setMetadata(graphicSetting, jsonEncode(saved));
    return bytes;
  }
}

Future<SelectedGraphic?> readGraphicTheme(
  Catalog c, {
  GraphicLoader load = viewedImage,
}) async {
  final raw = c.metadata(graphicSetting);
  if (raw == null) return null;
  try {
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['edition'] is! String ||
        data['path'] is! String ||
        data['version'] is! String ||
        data['image'] is! String ||
        data['overlay'] is! num) {
      return null;
    }
    final primary = ThemeArt.values
        .where((a) => a.name == (data['primary'] ?? 'tall'))
        .firstOrNull;
    final String id = data['edition'];
    if (primary == null || !primary.allows(data['path'], id)) return null;
    final image = base64Decode(data['image']);
    if (!await decodableImage(image)) return null;
    final files = <ThemeArt, GraphicFile>{
      primary: (path: data['path'], version: data['version']),
    };
    final images = <ThemeArt, Uint8List>{};
    final variants = data['variants'];
    for (final art in ThemeArt.values.where((a) => a != primary)) {
      final v = variants is Map ? variants[art.name] : null;
      if (v is! Map ||
          v['path'] is! String ||
          v['version'] is! String ||
          !art.allows(v['path'], id)) {
        continue;
      }
      files[art] = (path: v['path'], version: v['version']);
      if (v['image'] is String) {
        try {
          final bytes = base64Decode(v['image']);
          if (await decodableImage(bytes)) images[art] = bytes;
        } on FormatException {
          /* Keep the saved primary artwork available. */
        }
      }
    }
    // Older backups contain only the tall image. Resolve its siblings from the same official edition.
    final choice = graphicThemes(
      c,
      editionId: id,
    ).where((g) => g.files[primary]?.path == data['path']).firstOrNull;
    for (final entry
        in choice?.files.entries ?? const <MapEntry<ThemeArt, GraphicFile>>[]) {
      files.putIfAbsent(entry.key, () => entry.value);
    }
    return SelectedGraphic._(
      c,
      id,
      primary,
      (data['overlay'] as num).clamp(0, 1).toDouble(),
      files,
      image,
      images,
      load,
    );
  } on FormatException {
    return null;
  }
}

Future<SelectedGraphic> selectGraphicTheme(
  Catalog c,
  GraphicTheme choice, {
  GraphicLoader load = viewedImage,
  ThemeArt preferred = ThemeArt.tall,
}) async {
  final primary = choice.files.containsKey(preferred)
      ? preferred
      : choice.primary;
  final source = choice.files[primary]!;
  GraphicTheme? current() => graphicThemes(
    c,
    editionId: choice.edition,
  ).where((g) => g.files[primary] == source).firstOrNull;
  if (current() == null) throw const FormatException('테마 목록이 변경되었습니다.');
  final bytes = await load(source.path, source.version);
  if (!await decodableImage(bytes)) {
    throw const FormatException('이미지를 읽을 수 없습니다.');
  }
  final item = current();
  if (item == null) throw const FormatException('다운로드 중 테마 정보가 변경되었습니다.');
  final selected = SelectedGraphic._(
    c,
    item.edition,
    primary,
    .60,
    item.files,
    bytes,
    {},
    load,
  );
  c.setMetadata(graphicSetting, jsonEncode(selected._encode()));
  return selected;
}

void resetGraphicTheme(Catalog c) =>
    c.db.execute('DELETE FROM metadata WHERE key=?', [graphicSetting]);
