part of 'catalog.dart';

typedef IntegrityResult = ({
  int missing,
  int damaged,
  int replaced,
  bool hasManifest,
});

extension CatalogIntegrity on Catalog {
  // Include typed search fields as well as the retained API payload.
  ResultSet _records(String kind) => kind == 'card'
      ? db.select(
          '''SELECT id,name,norm,effect,payload, (SELECT json_group_array(json_array(kind,value) ORDER BY kind,value) FROM tags WHERE card=cards.id) AS tags FROM cards WHERE active=1''',
        )
      : db.select(
          'SELECT e.id,e.card,e.set_code,e.number,e.rarity,e.position,e.payload FROM editions e JOIN cards c ON c.id=e.card WHERE c.active=1',
        );

  String _digest(Row row) =>
      sha256.convert(utf8.encode(jsonEncode(row.values.toList()))).toString();

  void recordManifest() {
    db.execute('DELETE FROM install_manifest');
    final insert = db.prepare('INSERT INTO install_manifest VALUES(?,?,?)');
    try {
      for (final kind in ['card', 'edition']) {
        for (final row in _records(kind)) {
          insert.execute([kind, row['id'], _digest(row)]);
        }
      }
    } finally {
      insert.close();
    }
    setMetadata('hasManifest', '1');
  }

  IntegrityResult inspect() {
    var missing = 0, damaged = 0, replaced = 0;
    final hasManifest = metadata('hasManifest') == '1';
    transaction(() {
      damaged += db
          .select('PRAGMA integrity_check')
          .where((r) => r.values.first != 'ok')
          .length;
      damaged += db.select('PRAGMA foreign_key_check').length;
      for (final kind in ['card', 'edition']) {
        final expected = {
          for (final r in db.select(
            'SELECT id,digest FROM install_manifest WHERE kind=?',
            [kind],
          ))
            r['id']: r['digest'],
        };
        for (final row in _records(kind)) {
          final old = expected.remove(row['id']);
          if (hasManifest && old != _digest(row)) {
            damaged++;
            continue;
          }
          try {
            final json = jsonDecode(row['payload'] as String);
            if (json is! Json ||
                json['uuid'] != row['id'] ||
                (kind == 'card' && json['name'] != row['name']) ||
                (kind == 'edition' &&
                    json['card_id'] != null &&
                    json['card_id'] != row['card'])) {
              damaged++;
            }
          } on FormatException {
            damaged++;
          }
        }
        missing += expected.length;
      }
      if (damaged == 0 && missing == 0) replaced = reconcileSpoilers();
    });
    return (
      missing: missing,
      damaged: damaged,
      replaced: replaced,
      hasManifest: hasManifest,
    );
  }
}
