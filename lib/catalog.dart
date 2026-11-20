import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

typedef Json = Map<String, dynamic>;
const facets = [
  'Type',
  'Subtype',
  'Class',
  'Element',
  'Speed',
  'Set',
  'Rarity',
];
String normalizedName(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

class Filters {
  String text = '', costType = '', legality = '';
  int? minCost, maxCost, minLevel, maxLevel;
  bool editions = false;
  final selected = <String, Set<String>>{};
  final all = <String>{};
}

class Catalog {
  final Database db;
  Catalog(this.db) {
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('''
      CREATE TABLE IF NOT EXISTS cards(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, norm TEXT NOT NULL,
        spoiler INTEGER NOT NULL, active INTEGER NOT NULL DEFAULT 1,
        effect TEXT NOT NULL, payload TEXT NOT NULL, photo BLOB
      );
      CREATE INDEX IF NOT EXISTS by_name ON cards(norm);
      CREATE TABLE IF NOT EXISTS editions(
        id TEXT PRIMARY KEY, card TEXT NOT NULL REFERENCES cards(id),
        set_code TEXT, number TEXT, rarity TEXT, payload TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS by_print ON editions(set_code,number);
      CREATE INDEX IF NOT EXISTS prints_by_card ON editions(card);
      CREATE TABLE IF NOT EXISTS tags(
        card TEXT NOT NULL REFERENCES cards(id), kind TEXT NOT NULL, value TEXT NOT NULL,
        PRIMARY KEY(card,kind,value)
      );
      CREATE INDEX IF NOT EXISTS by_tag ON tags(kind,value,card);
      CREATE TABLE IF NOT EXISTS retired_editions(id TEXT PRIMARY KEY, card TEXT NOT NULL, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS replacements(local_id TEXT PRIMARY KEY, official_id TEXT NOT NULL REFERENCES cards(id));
      CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    ''');
    // Earlier catalogs inserted editions in API order without storing an ordinal.
    if (!db
        .select('PRAGMA table_info(editions)')
        .any((r) => r['name'] == 'position')) {
      transaction(() {
        db.execute(
          'ALTER TABLE editions ADD COLUMN position INTEGER NOT NULL DEFAULT 0',
        );
        db.execute(
          '''WITH ordinals AS MATERIALIZED (
          SELECT id, row_number() OVER (PARTITION BY card ORDER BY rowid)-1 AS n FROM editions
        ) UPDATE editions SET position=(SELECT n FROM ordinals WHERE ordinals.id=editions.id)''',
        );
      });
    }
    db.execute(
      'CREATE INDEX IF NOT EXISTS edition_order ON editions(card,position)',
    );
  }

  void transaction(void Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void insert(Json input, {bool spoiler = false, Uint8List? photo}) {
    final c = Json.of(input)..remove('result_editions');
    final prints = c.remove('editions') as List;
    final id = c['uuid'] as String;
    final name = c['name'] as String;
    if (name.trim().isEmpty || id.isEmpty) {
      throw const FormatException('빈 카드 식별자 또는 이름');
    }
    db.execute(
      'INSERT INTO cards(id,name,norm,spoiler,effect,payload,photo) VALUES(?,?,?,?,?,?,?)',
      [
        id,
        name,
        normalizedName(name),
        spoiler ? 1 : 0,
        c['effect_raw'] ?? '',
        jsonEncode(c),
        photo,
      ],
    );
    final speed = switch (c['speed']) {
      true => 'FAST',
      false => 'SLOW',
      _ => 'NONE',
    };
    final groups = {
      'Type': c['types'],
      'Subtype': c['subtypes'],
      'Class': c['classes'],
      'Element': c['elements'],
      'Speed': [speed],
    };
    for (final g in groups.entries) {
      for (final v in (g.value as List? ?? []).toSet()) {
        db.execute('INSERT INTO tags VALUES(?,?,?)', [id, g.key, v]);
      }
    }
    for (final (position, e) in prints.cast<Json>().indexed) {
      if (e['card_id'] != null && e['card_id'] != id) {
        throw const FormatException('인쇄판의 카드 ID 불일치');
      }
      db.execute(
        'INSERT INTO editions(id,card,set_code,number,rarity,payload,position) VALUES(?,?,?,?,?,?,?)',
        [
          e['uuid'] as String,
          id,
          e['set']?['prefix'],
          e['collector_number'],
          e['rarity']?.toString(),
          jsonEncode(e),
          position,
        ],
      );
    }
  }

  String? metadata(String key) =>
      db.select('SELECT value FROM metadata WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void setMetadata(String key, String value) =>
      db.execute('INSERT OR REPLACE INTO metadata VALUES(?,?)', [key, value]);
  String? get updated => metadata('updated');
  bool get wifiOnly => metadata('wifiOnly') == '1';
  bool get thumbnailGrid => metadata('thumbnailGrid') == '1';

  Map<String, List<String>> options() {
    final result = {for (final f in facets) f: <String>[]};
    for (final row in db.select(
      'SELECT DISTINCT kind,value FROM tags JOIN cards ON cards.id=tags.card WHERE active=1 ORDER BY value',
    )) {
      result[row['kind']]!.add(row['value'] as String);
    }
    for (final item in {'Set': 'set_code', 'Rarity': 'rarity'}.entries) {
      result[item.key] = db
          .select(
            'SELECT DISTINCT ${item.value} v FROM editions JOIN cards ON cards.id=editions.card WHERE active=1 AND ${item.value} IS NOT NULL ORDER BY v',
          )
          .map((r) => r['v'] as String)
          .toList();
    }
    return result;
  }

  List<Row> search(Filters f) {
    final args = <Object?>[];
    final clauses = ['c.active=1'];
    if (f.text.trim().isNotEmpty) {
      final term = f.text.trim();
      clauses.add(
        '''(instr(lower(c.name),lower(?))>0 OR instr(c.norm,lower(?))>0 OR instr(lower(c.effect),lower(?))>0
        OR EXISTS (SELECT 1 FROM editions t WHERE t.card=c.id AND instr(lower(json_extract(t.payload,'\$.effect_raw')),lower(?))>0))''',
      );
      args.addAll([term, term, term, term]);
    }
    final cost = "json_extract(c.payload,'\$.cost.value')";
    final level = "json_extract(c.payload,'\$.level')";
    if (f.costType.isNotEmpty) {
      clauses.add("json_extract(c.payload,'\$.cost.type')=?");
      args.add(f.costType);
    }
    if (f.minCost != null || f.maxCost != null) {
      clauses.add(
        "CAST($cost AS TEXT) GLOB '[0-9]*' AND CAST($cost AS TEXT) NOT GLOB '*[^0-9]*'",
      );
    }
    for (final (field, op, value) in [
      ('CAST($cost AS INTEGER)', '>=', f.minCost),
      ('CAST($cost AS INTEGER)', '<=', f.maxCost),
      (level, '>=', f.minLevel),
      (level, '<=', f.maxLevel),
    ]) {
      if (value != null) {
        clauses.add('$field $op ?');
        args.add(value);
      }
    }
    if (f.legality.isNotEmpty) {
      final limit =
          "coalesce(json_extract(c.payload,'\$.legality.STANDARD'),json_extract(c.payload,'\$.legality.standard'))";
      clauses.add(
        "c.spoiler=0 AND $limit IS ${f.legality == '제한' ? 'NOT ' : ''}NULL",
      );
    }
    String slots(int n) => List.filled(n, '?').join(',');
    for (final g in facets.where((g) => g != 'Set' && g != 'Rarity')) {
      final values = f.selected[g] ?? {};
      if (values.isEmpty) continue;
      clauses.add(
        '(SELECT count(*) FROM tags t WHERE t.card=c.id AND t.kind=? AND t.value IN (${slots(values.length)})) >= ?',
      );
      args.addAll([g, ...values, f.all.contains(g) ? values.length : 1]);
    }
    final editionConditions = <String>[];
    final editionArgs = <Object?>[];
    final coverage = <String>[];
    for (final (group, column) in [('Set', 'set_code'), ('Rarity', 'rarity')]) {
      final values = f.selected[group] ?? {};
      if (values.isEmpty) continue;
      editionConditions.add('e.$column IN (${slots(values.length)})');
      editionArgs.addAll(values);
      if (f.all.contains(group)) {
        coverage.add('COUNT(DISTINCT e.$column) = ${values.length}');
      }
    }
    if (editionConditions.isNotEmpty) {
      clauses.add(
        'EXISTS (SELECT 1 FROM editions e WHERE e.card=c.id AND ${editionConditions.join(' AND ')} GROUP BY e.card ${coverage.isEmpty ? '' : 'HAVING ${coverage.join(' AND ')}'})',
      );
      args.addAll(editionArgs);
      if (f.editions) {
        clauses.addAll(editionConditions);
        args.addAll(editionArgs);
      }
    }
    return db.select(
      'SELECT c.id,c.name,c.spoiler,${f.editions ? 'e.id AS edition,e.set_code,e.rarity' : 'NULL AS edition'} FROM cards c ${f.editions ? 'LEFT JOIN editions e ON e.card=c.id' : ''} WHERE ${clauses.join(' AND ')} ORDER BY c.norm,c.id ${f.editions ? ',e.id' : ''}',
      args,
    );
  }

  List<String> candidates(String localId) {
    final byPrint = db.select(
      '''SELECT DISTINCT c.id FROM editions local JOIN editions e
      ON local.set_code=e.set_code COLLATE NOCASE AND local.number=e.number COLLATE NOCASE
      JOIN cards c ON e.card=c.id WHERE local.card=? AND c.active=1 AND c.spoiler=0''',
      [localId],
    );
    final byName = db.select(
      '''SELECT c.id FROM cards local JOIN cards c ON local.norm=c.norm
      WHERE local.id=? AND c.active=1 AND c.spoiler=0''',
      [localId],
    );
    return {
      ...byPrint,
      ...byName,
    }.map((r) => r['id'] as String).toSet().toList();
  }

  void resolve(String localId, String officialId) {
    db.execute('INSERT INTO replacements VALUES(?,?)', [localId, officialId]);
    db.execute('UPDATE cards SET active=0 WHERE id=? AND spoiler=1', [localId]);
  }

  // Stage is a closed, independently validated SQLite file on the same device.
  void publish(String stage) {
    db.execute('ATTACH DATABASE ? AS incoming', [stage]);
    try {
      transaction(() {
        db.execute(
          '''INSERT OR REPLACE INTO retired_editions SELECT e.id,e.card,e.payload FROM editions e
          JOIN cards c ON c.id=e.card WHERE c.spoiler=0 AND e.id NOT IN (SELECT id FROM incoming.editions)''',
        );
        db.execute(
          'DELETE FROM retired_editions WHERE id IN (SELECT id FROM incoming.editions)',
        );
        db.execute('UPDATE cards SET active=0 WHERE spoiler=0');
        db.execute(
          'DELETE FROM tags WHERE card IN (SELECT id FROM incoming.cards)',
        );
        db.execute(
          'DELETE FROM editions WHERE card IN (SELECT id FROM incoming.cards)',
        );
        db.execute(
          '''INSERT INTO cards SELECT * FROM incoming.cards WHERE true
          ON CONFLICT(id) DO UPDATE SET name=excluded.name,norm=excluded.norm,active=1,effect=excluded.effect,payload=excluded.payload''',
        );
        db.execute('INSERT INTO tags SELECT * FROM incoming.tags');
        db.execute('INSERT INTO editions SELECT * FROM incoming.editions');
        for (final row in db.select(
          'SELECT id FROM cards WHERE spoiler=1 AND active=1',
        )) {
          final local = row['id'] as String;
          final matches = candidates(local);
          if (matches.length == 1) resolve(local, matches.single);
        }
        db.execute("INSERT OR REPLACE INTO metadata VALUES('updated',?)", [
          DateTime.now().toUtc().toIso8601String(),
        ]);
      });
    } finally {
      db.execute('DETACH DATABASE incoming');
    }
  }
}
