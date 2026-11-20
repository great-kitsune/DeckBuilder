import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

part 'integrity.dart';
part 'decks.dart';
part 'deck_recipe.dart';

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
    for (final prefix in ['', 'spoiler_']) {
      db.execute('''
      CREATE TABLE IF NOT EXISTS ${prefix}cards(
        id TEXT PRIMARY KEY, name TEXT NOT NULL, norm TEXT NOT NULL,
        spoiler INTEGER NOT NULL, active INTEGER NOT NULL DEFAULT 1,
        effect TEXT NOT NULL, payload TEXT NOT NULL, photo BLOB
      );
      CREATE INDEX IF NOT EXISTS ${prefix}by_name ON ${prefix}cards(norm);
      CREATE TABLE IF NOT EXISTS ${prefix}editions(
        id TEXT PRIMARY KEY, card TEXT NOT NULL REFERENCES ${prefix}cards(id),
        set_code TEXT, number TEXT, rarity TEXT, payload TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS ${prefix}by_print ON ${prefix}editions(set_code,number);
      CREATE INDEX IF NOT EXISTS ${prefix}prints_by_card ON ${prefix}editions(card);
      CREATE TABLE IF NOT EXISTS ${prefix}tags(
        card TEXT NOT NULL REFERENCES ${prefix}cards(id), kind TEXT NOT NULL, value TEXT NOT NULL,
        PRIMARY KEY(card,kind,value)
      );
      CREATE INDEX IF NOT EXISTS ${prefix}by_tag ON ${prefix}tags(kind,value,card);
      ''');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS decks(id INTEGER PRIMARY KEY, name TEXT NOT NULL CHECK(length(trim(name))>0));
      CREATE TABLE IF NOT EXISTS deck_entries(
        deck INTEGER NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
        zone TEXT NOT NULL CHECK(zone IN ('material','main','sideboard')),
        card TEXT NOT NULL, edition TEXT NOT NULL, quantity INTEGER NOT NULL CHECK(quantity>0),
        PRIMARY KEY(deck,zone,card,edition)
      );
      CREATE INDEX IF NOT EXISTS deck_entries_by_card ON deck_entries(card);
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
    db.execute('''
      CREATE VIEW IF NOT EXISTS library_cards AS SELECT * FROM cards UNION ALL SELECT * FROM spoiler_cards;
      CREATE VIEW IF NOT EXISTS library_tags AS SELECT * FROM tags UNION ALL SELECT * FROM spoiler_tags;
      CREATE VIEW IF NOT EXISTS library_editions AS SELECT * FROM editions UNION ALL SELECT * FROM spoiler_editions;
      CREATE TABLE IF NOT EXISTS install_manifest(kind TEXT, id TEXT, digest TEXT NOT NULL, PRIMARY KEY(kind,id));
    ''');
    if (db.select('SELECT 1 FROM cards WHERE spoiler=1 LIMIT 1').isNotEmpty) {
      transaction(() {
        db.execute('''
          INSERT INTO spoiler_cards SELECT * FROM cards WHERE spoiler=1;
          INSERT INTO spoiler_editions SELECT e.* FROM editions e JOIN cards c ON c.id=e.card WHERE c.spoiler=1;
          INSERT INTO spoiler_tags SELECT t.* FROM tags t JOIN cards c ON c.id=t.card WHERE c.spoiler=1;
          DELETE FROM tags WHERE card IN (SELECT id FROM cards WHERE spoiler=1);
          DELETE FROM editions WHERE card IN (SELECT id FROM cards WHERE spoiler=1);
          DELETE FROM cards WHERE spoiler=1;
        ''');
        reconcileSpoilers();
      });
    }
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
    final prefix = spoiler ? 'spoiler_' : '';
    final c = Json.of(input)..remove('result_editions');
    final prints = c.remove('editions') as List;
    final id = c['uuid'] as String;
    final name = c['name'] as String;
    if (name.trim().isEmpty || id.isEmpty) {
      throw const FormatException('빈 카드 식별자 또는 이름');
    }
    db.execute(
      'INSERT INTO ${prefix}cards(id,name,norm,spoiler,effect,payload,photo) VALUES(?,?,?,?,?,?,?)',
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
        db.execute('INSERT INTO ${prefix}tags VALUES(?,?,?)', [id, g.key, v]);
      }
    }
    for (final (position, e) in prints.cast<Json>().indexed) {
      if (e['card_id'] != null && e['card_id'] != id) {
        throw const FormatException('인쇄판의 카드 ID 불일치');
      }
      db.execute(
        'INSERT INTO ${prefix}editions(id,card,set_code,number,rarity,payload,position) VALUES(?,?,?,?,?,?,?)',
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
  bool get thumbnailGrid => metadata('thumbnailGrid') == '1';

  Map<String, List<String>> options() {
    final result = {for (final f in facets) f: <String>[]};
    for (final row in db.select(
      'SELECT DISTINCT kind,value FROM library_tags JOIN library_cards ON library_cards.id=library_tags.card WHERE active=1 ORDER BY value',
    )) {
      result[row['kind']]?.add(row['value'] as String);
    }
    for (final item in {'Set': 'set_code', 'Rarity': 'rarity'}.entries) {
      result[item.key] = db
          .select(
            'SELECT DISTINCT ${item.value} v FROM library_editions JOIN library_cards ON library_cards.id=library_editions.card WHERE active=1 AND ${item.value} IS NOT NULL ORDER BY v',
          )
          .map((r) => r['v'] as String)
          .toList();
    }
    return result;
  }

  List<Row> search(Filters f, {DeckCost? requiredCost}) {
    final args = <Object?>[];
    final clauses = ['c.active=1'];
    if (f.text.trim().isNotEmpty) {
      final term = f.text.trim();
      clauses.add(
        '''(instr(lower(c.name),lower(?))>0 OR instr(c.norm,lower(?))>0 OR instr(lower(c.effect),lower(?))>0
        OR EXISTS (SELECT 1 FROM library_editions t WHERE t.card=c.id AND instr(lower(json_extract(t.payload,'\$.effect_raw')),lower(?))>0))''',
      );
      args.addAll([term, term, term, term]);
    }
    final cost = "json_extract(c.payload,'\$.cost.value')";
    final level = "json_extract(c.payload,'\$.level')";
    final costType = requiredCost?.name ?? f.costType;
    if (costType.isNotEmpty) {
      clauses.add("json_extract(c.payload,'\$.cost.type')=?");
      args.add(costType);
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
        '(SELECT count(*) FROM library_tags t WHERE t.card=c.id AND t.kind=? AND t.value IN (${slots(values.length)})) >= ?',
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
        'EXISTS (SELECT 1 FROM library_editions e WHERE e.card=c.id AND ${editionConditions.join(' AND ')} GROUP BY e.card ${coverage.isEmpty ? '' : 'HAVING ${coverage.join(' AND ')}'})',
      );
      args.addAll(editionArgs);
      if (f.editions) {
        clauses.addAll(editionConditions);
        args.addAll(editionArgs);
      }
    }
    return db.select(
      'SELECT c.id,c.name,c.spoiler,json_extract(c.payload,\'\$.cost.type\') cost_type,${f.editions ? 'e.id AS edition,e.set_code,e.number,e.rarity' : 'NULL AS edition'} FROM library_cards c ${f.editions ? 'LEFT JOIN library_editions e ON e.card=c.id' : ''} WHERE ${clauses.join(' AND ')} ORDER BY c.norm,c.id ${f.editions ? ',e.id' : ''}',
      args,
    );
  }

  List<String> candidates(String localId) {
    final local = db.select(
      'SELECT name,payload FROM spoiler_cards WHERE id=?',
      [localId],
    ).single;
    final data = jsonDecode(local['payload'] as String) as Json;
    final names = {
      normalizedName(local['name'] as String),
      normalizedName(data['english_name'] as String? ?? ''),
    }..remove('');
    final named = db
        .select(
          'SELECT id FROM cards WHERE active=1 AND norm IN (${List.filled(names.length, '?').join(',')}) ORDER BY id',
          names.toList(),
        )
        .map((r) => r['id'] as String)
        .toList();
    if (named.length == 1) return named;
    final printed = db
        .select(
          '''SELECT DISTINCT e.card FROM spoiler_editions s JOIN editions e
      ON s.set_code=e.set_code COLLATE NOCASE AND s.number=e.number COLLATE NOCASE
      JOIN cards c ON c.id=e.card WHERE s.card=? AND c.active=1 ORDER BY e.card''',
          [localId],
        )
        .map((r) => r['card'] as String)
        .toList();
    if (named.isEmpty) return printed;
    final matching = named.where(printed.contains).toList();
    return matching.isEmpty ? named : matching;
  }

  ({int decks, int copies}) spoilerUsage(String id) {
    final row = db.select(
      'SELECT count(DISTINCT deck) decks,coalesce(sum(quantity),0) copies FROM deck_entries WHERE card=?',
      [id],
    ).single;
    return (decks: row['decks'] as int, copies: row['copies'] as int);
  }

  void deleteSpoiler(
    String id, {
    required ({int decks, int copies}) confirmedUsage,
  }) {
    transaction(() {
      if (db
          .select(
            '''SELECT 1 FROM spoiler_cards WHERE id=? AND active IN (1,2)
        AND NOT EXISTS (SELECT 1 FROM replacements WHERE local_id=?)''',
            [id, id],
          )
          .isEmpty) {
        throw StateError('이미 삭제되었거나 공식 카드로 교체된 카드입니다.');
      }
      if (spoilerUsage(id) != confirmedUsage) {
        throw StateError('덱 구성이 변경되었습니다. 삭제할 내용을 다시 확인하세요.');
      }
      db.execute('DELETE FROM deck_entries WHERE card=?', [id]);
      db.execute('DELETE FROM spoiler_tags WHERE card=?', [id]);
      db.execute('DELETE FROM spoiler_editions WHERE card=?', [id]);
      db.execute('DELETE FROM spoiler_cards WHERE id=?', [id]);
    });
  }

  void resolve(String localId, String officialId) {
    // A background install may have resolved a detail page that was left open.
    if (db.select('SELECT 1 FROM replacements WHERE local_id=?', [
      localId,
    ]).isNotEmpty) {
      return;
    }
    _replaceDeckCard(localId, officialId);
    db.execute('INSERT INTO replacements VALUES(?,?)', [localId, officialId]);
    db.execute('UPDATE spoiler_cards SET active=0 WHERE id=?', [localId]);
  }

  int reconcileSpoilers({String? only}) {
    final rows = db.select(
      'SELECT id FROM spoiler_cards WHERE active<>0 ${only == null ? '' : 'AND id=?'}',
      [?only],
    );
    var resolved = 0;
    for (final row in rows) {
      final id = row['id'] as String;
      final matches = candidates(id);
      if (matches.length == 1) {
        resolve(id, matches.single);
        resolved++;
      } else {
        // Ambiguous references stay available for manual selection in Settings.
        db.execute('UPDATE spoiler_cards SET active=? WHERE id=?', [
          matches.isEmpty ? 1 : 2,
          id,
        ]);
      }
    }
    return resolved;
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
        reconcileSpoilers();
        recordManifest();
        db.execute("INSERT OR REPLACE INTO metadata VALUES('updated',?)", [
          DateTime.now().toUtc().toIso8601String(),
        ]);
      });
    } finally {
      db.execute('DETACH DATABASE incoming');
    }
  }
}
