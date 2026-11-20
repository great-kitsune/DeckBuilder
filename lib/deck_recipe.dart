part of 'catalog.dart';

String omnidexText(List<DeckEntry> entries) {
  if (entries.isEmpty) throw const FormatException('덱에 카드를 먼저 추가하세요.');
  final sections = <String>[];
  for (final zone in DeckZone.values) {
    final cards = <String, int>{};
    for (final e in entries.where((e) => e.zone == zone)) {
      if (e.spoiler) throw FormatException('스포일러 카드가 포함되어 있습니다 · ${e.name}');
      final name = e.officialName.trim();
      if (name.contains(RegExp(r'[\r\n]'))) {
        throw FormatException('카드명을 확인하세요 · $name');
      }
      cards.update(name, (n) => n + e.quantity, ifAbsent: () => e.quantity);
    }
    final names = cards.keys.toList()..sort();
    sections.add(
      [
        '# ${zone.label}',
        for (final name in names) '${cards[name]} $name',
      ].join('\n'),
    );
  }
  return sections.join('\n\n');
}

typedef RecipeLine = ({int number, DeckZone zone, String name, int quantity});
const recipeSizeLimit = 256 * 1024;

List<RecipeLine> parseDeckRecipe(String input) {
  if (input.length > recipeSizeLimit ||
      utf8.encode(input).length > recipeSizeLimit) {
    throw const FormatException('레시피는 256 KB까지 지원합니다.');
  }
  final lines = const LineSplitter().convert(
    input.replaceFirst(RegExp('^\uFEFF'), ''),
  );
  final rows = <RecipeLine>[];
  final cardLine = RegExp(r'^(\d+)\s+(.+)$');
  DeckZone? zone;
  for (final (i, raw) in lines.indexed) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#')) {
      final label = normalizedName(line.substring(1));
      zone = DeckZone.values
          .where((z) => normalizedName(z.label) == label)
          .firstOrNull;
      if (zone == null) throw FormatException('${i + 1}행 · 알 수 없는 구역 "$line"');
      continue;
    }
    if (zone == null) {
      throw FormatException('${i + 1}행 · 카드 앞에 # Main Deck 등의 구역명이 필요합니다.');
    }
    final match = cardLine.firstMatch(line);
    final count = int.tryParse(match?.group(1) ?? '');
    if (match == null || count == null || count < 1 || count > 2147483647) {
      throw FormatException('${i + 1}행 · 양의 정수 수량과 카드명을 입력하세요.');
    }
    rows.add((
      number: i + 1,
      zone: zone,
      quantity: count,
      name: match.group(2)!.trim(),
    ));
  }
  if (rows.isEmpty) throw const FormatException('가져올 카드가 없습니다.');
  return rows;
}

typedef RecipeCandidate = ({
  String id,
  String name,
  DeckCost cost,
  String printing,
});

extension RecipeStorage on Catalog {
  Map<String, List<RecipeCandidate>> recipeCandidates(List<RecipeLine> lines) {
    final names = {for (final row in lines) normalizedName(row.name)};
    final matches = <String, List<RecipeCandidate>>{};
    for (final card in db.select("""
      SELECT c.id,c.name,c.norm,json_extract(c.payload,'\$.english_name') english_name,
             json_extract(c.payload,'\$.cost.type') cost_type,
             (SELECT e.set_code || ' #' || e.number FROM editions e WHERE e.card=c.id ORDER BY position,id LIMIT 1) printing
      FROM cards c WHERE c.active=1 ORDER BY c.id""")) {
      final aliases = {
        card['norm'] as String,
        normalizedName(card['english_name'] as String? ?? ''),
      };
      for (final name in aliases.where(names.contains)) {
        (matches[name] ??= []).add((
          id: card['id'] as String,
          name: card['name'] as String,
          cost: DeckCost.parse(card['cost_type']),
          printing: card['printing'] as String? ?? '',
        ));
      }
    }
    return matches;
  }

  DeckInfo importRecipe(
    String name,
    List<RecipeLine> lines, {
    Map<(String, DeckZone), String> choices = const {},
  }) {
    if (name.trim().isEmpty || lines.isEmpty) {
      throw const FormatException('덱 이름과 레시피가 필요합니다.');
    }
    late int deck;
    transaction(() {
      final matches = recipeCandidates(lines);
      deck = createDeck(name);
      for (final row in lines) {
        final key = normalizedName(row.name);
        final all = matches[key] ?? [];
        final cards = all.where((c) => c.cost.accepts(row.zone)).toList();
        final chosen = choices[(key, row.zone)];
        final card = chosen == null
            ? (cards.length == 1 ? cards.single : null)
            : cards.where((c) => c.id == chosen).firstOrNull;
        if (card == null) {
          final problem = all.isEmpty
              ? '공식 카드 DB에서 찾을 수 없습니다'
              : cards.isEmpty
              ? '${row.zone.label}에 넣을 수 없습니다'
              : '동명 카드 선택이 필요합니다';
          throw FormatException('${row.number}행 · ${row.name} · $problem');
        }
        try {
          _checkDeckRule(
            deck,
            card.id,
            row.zone,
            row.quantity,
            activeOnly: true,
          );
        } on StateError catch (e) {
          throw FormatException('${row.number}행 · ${row.name} · ${e.message}');
        }
        final edition = db.select(
          'SELECT id FROM editions WHERE card=? ORDER BY position,id LIMIT 1',
          [card.id],
        ).firstOrNull;
        _put(
          deck,
          row.zone,
          card.id,
          edition?['id'] as String? ?? '',
          row.quantity,
        );
      }
    });
    return (id: deck, name: name.trim());
  }
}
