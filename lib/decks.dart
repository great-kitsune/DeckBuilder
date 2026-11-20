part of 'catalog.dart';

enum DeckZone {
  material('Material Deck'),
  main('Main Deck'),
  sideboard('Sideboard');

  final String label;
  const DeckZone(this.label);
}

enum DeckCost {
  reserve(DeckZone.main, 'Main', 4, 1),
  memory(DeckZone.material, 'Material', 1, 3),
  other(null, '', null, 0);

  final DeckZone? primary;
  final String label;
  final int? limit;
  final int points;
  const DeckCost(this.primary, this.label, this.limit, this.points);

  static DeckCost parse(Object? value) => switch (value) {
    'reserve' => reserve,
    'memory' => memory,
    _ => other,
  };

  bool accepts(DeckZone zone) => zone == primary || zone == DeckZone.sideboard;
}

typedef DeckCounts = Map<(DeckCost, String), ZoneCopies>;

class ZoneCopies {
  final int primary, side;
  const ZoneCopies([this.primary = 0, this.side = 0]);

  String label(DeckCost cost) => [
    if (cost.primary != null) '${cost.label}에 $primary장',
    'Side에 $side장',
  ].join(', ');

  bool allows(DeckCost cost, int extra) =>
      extra == 0 || cost.limit == null || primary + side + extra <= cost.limit!;
}

DeckCounts countCopies(Iterable<DeckEntry> entries) {
  final counts = <(DeckCost, String), ZoneCopies>{};
  for (final e in entries) {
    if (!e.cost.accepts(e.zone)) continue;
    final key = (e.cost, normalizedName(e.name));
    final current = counts[key] ?? const ZoneCopies();
    counts[key] = e.zone == DeckZone.sideboard
        ? ZoneCopies(current.primary, current.side + e.quantity)
        : ZoneCopies(current.primary + e.quantity, current.side);
  }
  return counts;
}

typedef DeckInfo = ({int id, String name});
typedef DeckEntry = ({
  int deck,
  DeckZone zone,
  String card,
  String edition,
  int quantity,
  DeckCost cost,
  bool spoiler,
  String name,
  String officialName,
  String printing,
  String? status,
});

extension DeckStorage on Catalog {
  List<DeckInfo> decks() => [
    for (final row in db.select(
      'SELECT id,name FROM decks ORDER BY name COLLATE NOCASE,id',
    ))
      (id: row['id'] as int, name: row['name'] as String),
  ];

  int createDeck(String name) {
    db.execute('INSERT INTO decks(name) VALUES(?)', [name.trim()]);
    return db.lastInsertRowId;
  }

  void renameDeck(int id, String name) =>
      db.execute('UPDATE decks SET name=? WHERE id=?', [name.trim(), id]);

  void deleteDeck(int id) => db.execute('DELETE FROM decks WHERE id=?', [id]);

  int duplicateDeck(DeckInfo deck) {
    late int copy;
    transaction(() {
      copy = createDeck('${deck.name} 복사본');
      db.execute(
        '''INSERT INTO deck_entries SELECT ?,zone,card,edition,quantity
        FROM deck_entries WHERE deck=?''',
        [copy, deck.id],
      );
    });
    return copy;
  }

  List<DeckEntry> deckEntries(int deck) {
    final rows = db.select(
      '''
      SELECT d.*,json_extract(c.payload,'\$.english_name') english_name,COALESCE(c.name,s.name,d.card) name,COALESCE(s.spoiler,0) spoiler,
        json_extract(COALESCE(c.payload,s.payload),'\$.cost.type') cost_type,
        COALESCE(c.active,s.active,0) active,COALESCE(e.id,se.id) current_print,
        COALESCE(e.set_code,se.set_code,json_extract(r.payload,'\$.set.prefix')) set_code,
        COALESCE(e.number,se.number,json_extract(r.payload,'\$.collector_number')) number
      FROM deck_entries d
      LEFT JOIN cards c ON c.id=d.card
      LEFT JOIN spoiler_cards s ON s.id=d.card
      LEFT JOIN editions e ON e.id=d.edition AND e.card=d.card
      LEFT JOIN spoiler_editions se ON se.id=d.edition AND se.card=d.card
      LEFT JOIN retired_editions r ON r.id=d.edition AND r.card=d.card
      WHERE d.deck=? ORDER BY COALESCE(c.norm,s.norm),d.card,d.edition
    ''',
      [deck],
    );
    return [
      for (final r in rows)
        (
          deck: deck,
          zone: DeckZone.values.byName(r['zone'] as String),
          card: r['card'] as String,
          edition: r['edition'] as String,
          quantity: r['quantity'] as int,
          cost: DeckCost.parse(r['cost_type']),
          spoiler: r['spoiler'] == 1,
          name: r['name'] as String,
          officialName:
              (r['english_name'] as String?)?.trim().isNotEmpty == true
              ? (r['english_name'] as String).trim()
              : r['name'] as String,
          printing: [
            r['set_code'],
            if (r['number'] != null) '#${r['number']}',
          ].nonNulls.join(' '),
          status: switch ((r['spoiler'], r['active'])) {
            (1, 2) => '스포일러 · 공식 카드 선택 필요',
            (1, _) => '스포일러',
            (_, 0) => '공식 목록에서 제외됨',
            _ when r['edition'] != '' && r['current_print'] == null => '이전 인쇄판',
            _ => null,
          },
        ),
    ];
  }

  void _put(
    int deck,
    DeckZone zone,
    String card,
    String edition,
    int quantity,
  ) {
    db.execute(
      '''INSERT INTO deck_entries VALUES(?,?,?,?,?)
      ON CONFLICT(deck,zone,card,edition) DO UPDATE SET quantity=quantity+excluded.quantity''',
      [deck, zone.name, card, edition, quantity],
    );
  }

  void _checkDeckRule(
    int deck,
    String card,
    DeckZone zone,
    int count, {
    DeckZone? from,
    bool activeOnly = false,
  }) {
    final row = db
        .select(
          """SELECT name,active,json_extract(payload,'\$.cost.type') cost_type
         FROM library_cards WHERE id=?""",
          [card],
        )
        .firstOrNull;
    if (row == null || (activeOnly && row['active'] != 1)) {
      throw StateError('카드 정보가 변경되었습니다. 검색 결과를 다시 확인하세요.');
    }
    final cost = DeckCost.parse(row['cost_type']);
    if (!cost.accepts(zone)) {
      throw StateError('이 비용 종류는 ${zone.label}에 넣을 수 없습니다.');
    }
    if (from != null && cost.accepts(from)) return;
    final key = (cost, normalizedName(row['name'] as String));
    final copies = countCopies(deckEntries(deck))[key] ?? const ZoneCopies();
    if (!copies.allows(cost, count)) {
      throw StateError(
        '동명 카드는 ${cost.label}과 Side 합계 ${cost.limit}장까지 넣을 수 있습니다.',
      );
    }
  }

  void addToDeck(int deck, DeckZone zone, String card, String? edition) {
    transaction(() {
      _checkDeckRule(deck, card, zone, 1, activeOnly: true);
      final prints = db.select(
        '''SELECT id FROM library_editions WHERE card=?
        AND (? IS NULL OR id=?) ORDER BY position,id LIMIT 1''',
        [card, edition, edition],
      );
      if (edition != null && prints.isEmpty) {
        throw StateError('인쇄판 정보가 변경되었습니다.');
      }
      _put(deck, zone, card, prints.firstOrNull?['id'] as String? ?? '', 1);
    });
  }

  void incrementEntry(DeckEntry e) {
    transaction(() {
      _checkDeckRule(e.deck, e.card, e.zone, 1);
      db.execute(
        '''UPDATE deck_entries SET quantity=quantity+1
      WHERE deck=? AND zone=? AND card=? AND edition=?''',
        [e.deck, e.zone.name, e.card, e.edition],
      );
      if (db.updatedRows == 0) throw StateError('항목이 변경되었습니다.');
    });
  }

  // Moving across zones and removing the last copy both commit atomically.
  void takeCopies(DeckEntry e, int count, {DeckZone? to}) {
    if (count <= 0 || to == e.zone) throw ArgumentError('이동 수량 또는 구역을 확인하세요.');
    transaction(() {
      const where = 'WHERE deck=? AND zone=? AND card=? AND edition=?';
      final key = [e.deck, e.zone.name, e.card, e.edition];
      final row = db
          .select('SELECT quantity FROM deck_entries $where', key)
          .firstOrNull;
      if (row == null || (row['quantity'] as int) < count) {
        throw StateError('항목이 변경되었습니다.');
      }
      if (to != null) _checkDeckRule(e.deck, e.card, to, count, from: e.zone);
      if (row['quantity'] == count) {
        db.execute('DELETE FROM deck_entries $where', key);
      } else {
        db.execute('UPDATE deck_entries SET quantity=quantity-? $where', [
          count,
          ...key,
        ]);
      }
      if (to != null) _put(e.deck, to, e.card, e.edition, count);
    });
  }

  // Called in the same transaction as the catalog's local-to-official mapping.
  void _replaceDeckCard(String local, String official) {
    final entries = db.select('SELECT * FROM deck_entries WHERE card=?', [
      local,
    ]);
    for (final row in entries) {
      final prints = db.select(
        '''SELECT e.id FROM editions e JOIN spoiler_editions s
        ON e.set_code=s.set_code COLLATE NOCASE AND e.number=s.number COLLATE NOCASE
        WHERE e.card=? AND s.card=? AND s.id=?''',
        [official, local, row['edition']],
      );
      // With no unique match keep the official card without guessing a printing.
      final edition = prints.length == 1 ? prints.single['id'] as String : '';
      _put(
        row['deck'] as int,
        DeckZone.values.byName(row['zone'] as String),
        official,
        edition,
        row['quantity'] as int,
      );
    }
    db.execute('DELETE FROM deck_entries WHERE card=?', [local]);
  }
}
