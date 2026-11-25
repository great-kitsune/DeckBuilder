import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog.dart';

const backupFormat = 1;
const backupByteLimit = 384 * 1024 * 1024;
const userSettings = ['thumbnailGrid'];
const _users = {
  'decks': 'id,name',
  'spoiler_cards': 'id,name,norm,spoiler,active,effect,payload,photo',
  'spoiler_editions': 'id,card,set_code,number,rarity,payload,position',
  'spoiler_tags': 'card,kind,value',
  'replacements': 'local_id,official_id',
  'deck_entries': 'deck,zone,card,edition,quantity',
  'metadata': 'key,value',
};
const _official = {
  'cards': 'id,name,norm,spoiler,active,effect,payload,photo',
  'editions': 'id,card,set_code,number,rarity,payload,position',
  'tags': 'card,kind,value',
  'retired_editions': 'id,card,payload',
  'install_manifest': 'kind,id,digest',
};
String get _preferences =>
    "key IN (${userSettings.map((s) => "'$s'").join(',')})";
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
void _require(bool ok, String message) {
  if (!ok) throw FormatException(message);
}

void _check(Database db) {
  _require(
    db.select('PRAGMA integrity_check').every((r) => r.values.first == 'ok') &&
        db.select('PRAGMA foreign_key_check').isEmpty,
    'SQLite 무결성 또는 참조 오류',
  );
}

void _size(int bytes) =>
    _require(bytes <= backupByteLimit, '백업 크기 한도(384 MB)를 초과했습니다.');

/// Obtain both the JSON and optional full catalog from the same WAL snapshot.
Uint8List createBackup(String path, bool full, String appVersion) {
  final dir = Directory.systemTemp.createTempSync('deck-backup-');
  try {
    final snapshot = File('${dir.path}/snapshot.sqlite');
    final live = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      live.execute('VACUUM INTO ?', [snapshot.path]);
    } finally {
      live.close();
    }
    final fileData = <String, Uint8List>{};
    final data = <String, List<Json>>{};
    final db = sqlite3.open(snapshot.path, mode: OpenMode.readOnly);
    String? updated;
    try {
      _check(db);
      updated =
          db
                  .select("SELECT value FROM metadata WHERE key='updated'")
                  .firstOrNull?['value']
              as String?;
      for (final entry in _users.entries) {
        final rows = <Json>[];
        for (final r in db.select(
          'SELECT ${entry.value} FROM ${entry.key} ${entry.key == 'metadata' ? 'WHERE $_preferences' : ''}',
        )) {
          final row = Json.of(r);
          if (row['photo'] is Uint8List) {
            final key = 'spoilers/${rows.length}.bin';
            fileData[key] = row['photo'] as Uint8List;
            row['photo'] = key;
          }
          rows.add(row);
        }
        data[entry.key] = rows;
      }
    } finally {
      db.close();
    }
    fileData['user_data.json'] = utf8.encode(jsonEncode(data));
    if (full) {
      _size(snapshot.lengthSync());
      fileData['catalog.sqlite'] = snapshot.readAsBytesSync();
    }
    _size(fileData.values.fold(0, (n, b) => n + b.length));
    fileData['manifest.json'] = utf8.encode(
      jsonEncode({
        'format_version': backupFormat,
        'app_version': appVersion,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'catalog_updated_at': updated,
        'includes_catalog': full,
        'schema_version': catalogSchemaVersion,
        'sha256': fileData.map((k, b) => MapEntry(k, _hash(b))),
        'counts': data.map((k, v) => MapEntry(k, v.length)),
      }),
    );
    final archive = Archive();
    for (final f in fileData.entries) {
      archive.add(ArchiveFile.bytes(f.key, f.value));
    }
    final bytes = ZipEncoder().encodeBytes(archive);
    _size(bytes.length);
    return bytes;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

typedef BackupPreview = ({
  String stage,
  bool full,
  int decks,
  int spoilers,
  int entries,
});
void _copy(Database db, Map<String, String> tables, {String source = 'donor'}) {
  for (final t in tables.entries) {
    db.execute(
      'INSERT INTO main.${t.key}(${t.value}) SELECT ${t.value} FROM $source.${t.key}',
    );
  }
}

void _missingOfficial(Database db, String id) {
  db.execute(
    'INSERT OR IGNORE INTO cards(id,name,norm,spoiler,active,effect,payload) VALUES(?,?,?,0,0,?,?)',
    [
      id,
      id,
      normalizedName(id),
      '',
      jsonEncode({'uuid': id, 'name': id}),
    ],
  );
}

BackupPreview prepareRestore(Uint8List bytes, bool full, String scratch) {
  _size(bytes.length);
  final decoder = ZipDecoder();
  final archive = decoder.decodeBytes(bytes, throwOnError: true);
  final files = <String, Uint8List>{};
  var total = 0;
  for (final f in archive) {
    _require(
      f.isFile &&
          !f.isSymbolicLink &&
          !files.containsKey(f.name) &&
          ([
                'manifest.json',
                'user_data.json',
                'catalog.sqlite',
              ].contains(f.name) ||
              RegExp(r'^spoilers/[0-9]+\.bin$').hasMatch(f.name)),
      '알 수 없는 백업 파일',
    );
    total += f.size;
    _size(total);
    final content = f.content;
    _require(content.length == f.size, '파일 길이 오류');
    files[f.name] = content;
  }
  final m = jsonDecode(utf8.decode(files.remove('manifest.json')!)) as Json;
  _require(
    m['format_version'] == backupFormat &&
        m['schema_version'] is int &&
        m['schema_version'] <= catalogSchemaVersion,
    '지원하지 않는 백업 또는 DB 버전',
  );
  _require(
    m['includes_catalog'] == full &&
        full == files.containsKey('catalog.sqlite'),
    '선택한 복원 방식과 백업 종류가 다릅니다.',
  );
  final hashes = m['sha256'] as Json;
  _require(
    hashes.length == files.length &&
        files.entries.every((e) => hashes[e.key] == _hash(e.value)),
    '백업 파일 해시 불일치',
  );
  final rows = jsonDecode(utf8.decode(files.remove('user_data.json')!)) as Json;
  final counts = m['counts'] as Json;
  final stage = '$scratch/validated.sqlite';
  _require(!File(stage).existsSync(), '임시 DB 경로 충돌');
  final db = sqlite3.open(stage);
  try {
    final catalog = Catalog(db);
    if (full) {
      final snapshot = File('$scratch/source.sqlite')
        ..writeAsBytesSync(files.remove('catalog.sqlite')!);
      final raw = sqlite3.open(snapshot.path, mode: OpenMode.readOnly);
      try {
        raw.execute('PRAGMA trusted_schema=OFF');
        _require(raw.userVersion == m['schema_version'], '일치하지 않는 DB 버전');
        final tables = raw
            .select(
              "SELECT name FROM pragma_table_list WHERE schema='main' AND type='table'",
            )
            .map((r) => r['name'])
            .toSet();
        _require(
          [..._official.keys, ..._users.keys].every(tables.contains),
          '필수 DB 테이블 누락',
        );
        _check(raw);
      } finally {
        raw.close();
      }
      db.execute('PRAGMA trusted_schema=OFF');
      db.execute('ATTACH DATABASE ? AS donor', [snapshot.path]);
    }
    catalog.transaction(() {
      if (full) {
        _copy(db, _official);
        db.execute(
          'INSERT INTO main.metadata SELECT key,value FROM donor.metadata WHERE NOT ($_preferences)',
        );
      }
      for (final t in _users.entries) {
        final records = rows[t.key] as List;
        _require(records.length == counts[t.key], '레코드 수 불일치 · ${t.key}');
        final columns = t.value.split(',');
        final insert = db.prepare(
          'INSERT INTO ${t.key}(${t.value}) VALUES(${List.filled(columns.length, '?').join(',')})',
        );
        try {
          for (final value in records) {
            final row = Json.of(value as Json);
            _require(
              row.length == columns.length && columns.every(row.containsKey),
              '레코드 필드 오류',
            );
            if (t.key == 'metadata') {
              _require(userSettings.contains(row['key']), '설정 키 오류');
            }
            if (row['photo'] != null) {
              final photo = files.remove(row['photo']);
              _require(photo != null, '스포일러 이미지 누락');
              row['photo'] = photo;
            }
            if (t.key == 'spoiler_cards' || t.key == 'spoiler_editions') {
              final payload = jsonDecode(row['payload'] as String);
              _require(
                payload is Map && payload['uuid'] == row['id'],
                '스포일러 UUID 오류',
              );
            }
            if (t.key == 'replacements' && !full) {
              _missingOfficial(db, row['official_id'] as String);
            }
            insert.execute([for (final key in columns) row[key]]);
          }
        } finally {
          insert.close();
        }
      }
      _require(files.isEmpty, '참조되지 않은 백업 파일');
      _check(db);
    });
    if (full) {
      final integrity = catalog.inspect(resolveSpoilers: false);
      _require(
        integrity.damaged == 0 && integrity.missing == 0,
        '공식 DB 무결성 검사 실패',
      );
    }
    return (
      stage: stage,
      full: full,
      decks: counts['decks'] as int,
      spoilers: counts['spoiler_cards'] as int,
      entries: counts['deck_entries'] as int,
    );
  } finally {
    db.close();
  }
}

/// Import only validated table rows, keeping the live WAL and connections intact.
void applyRestore(Catalog live, BackupPreview plan) {
  final db = live.db;
  db.execute('ATTACH DATABASE ? AS donor', [plan.stage]);
  try {
    live.transaction(() {
      for (final table in _users.keys.toList().reversed) {
        db.execute(
          'DELETE FROM main.$table ${table == 'metadata' && !plan.full ? 'WHERE $_preferences' : ''}',
        );
      }
      if (plan.full) {
        for (final table in _official.keys.toList().reversed) {
          db.execute('DELETE FROM main.$table');
        }
        _copy(db, _official);
      } else {
        for (final row in db.select(
          'SELECT DISTINCT official_id FROM donor.replacements',
        )) {
          _missingOfficial(db, row['official_id'] as String);
        }
      }
      _copy(db, _users);
      _check(db);
    });
  } finally {
    db.execute('DETACH DATABASE donor');
  }
}
