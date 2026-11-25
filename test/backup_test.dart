import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card, edition;

void main() {
  late Directory tmp;
  late Catalog source;
  late String path;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync();
    path = '${tmp.path}/source.db';
    source = Catalog(sqlite3.open(path));
    source.db.execute('PRAGMA journal_mode=WAL');
    source.insert(
      card('official', 'Official', prints: [edition('print', 'SET', '01', 1)]),
    );
    source.insert(
      card('spoiler', 'Spoiler'),
      spoiler: true,
      photo: Uint8List.fromList([1, 4, 9]),
    );
    source.db.execute("INSERT INTO replacements VALUES('old','official')");
    final id = source.createDeck('Twins');
    source.createDeck('Twins');
    source.addToDeck(id, DeckZone.material, 'official', 'print');
    source.addToDeck(id, DeckZone.sideboard, 'spoiler', null);
    source.setMetadata('thumbnailGrid', '1');
    source.setMetadata('updated', 'yesterday');
    source.recordManifest();
  });
  tearDown(() {
    source.db.close();
    tmp.deleteSync(recursive: true);
  });
  for (final full in [false, true]) {
    test('restore ${full ? 'full' : 'user'} backup into fresh database', () {
      final bytes = createBackup(path, full, '1.0+3');
      final plan = prepareRestore(bytes, full, tmp.path);
      final fresh = Catalog(sqlite3.openInMemory());
      addTearDown(fresh.db.close);
      fresh.createDeck('Old');
      applyRestore(fresh, plan);
      expect(fresh.decks(), source.decks());
      expect(
        fresh.db
            .select('SELECT * FROM deck_entries')
            .map((r) => r.values.toList()),
        source.db
            .select('SELECT * FROM deck_entries')
            .map((r) => r.values.toList()),
      );
      expect(fresh.thumbnailGrid, true);
      expect(
        fresh.db.select('SELECT photo FROM spoiler_cards').single['photo'],
        [1, 4, 9],
      );
      expect(
        fresh.db
            .select('SELECT official_id FROM replacements')
            .single['official_id'],
        'official',
      );
      expect(fresh.updated, full ? 'yesterday' : null);
      expect(fresh.search(Filters()).length, full ? 2 : 1);
      if (full) expect(fresh.inspect().damaged, 0);
    });
  }
  test('legacy populated migration is atomic and repeatable', () {
    source.db.userVersion = 0;
    Catalog(source.db);
    Catalog(source.db);
    expect(source.decks().length, 2);
    expect(source.thumbnailGrid, true);
    expect(
      source.db.select('SELECT photo FROM spoiler_cards').single['photo'],
      [1, 4, 9],
    );
    expect(source.db.userVersion, catalogSchemaVersion);
    source.db.userVersion = 100;
    expect(() => Catalog(source.db), throwsFormatException);
  });
  test(
    'reject damaged and unsupported archives without changing live rows',
    () {
      final original = createBackup(path, false, '1');
      for (final version in [false, true]) {
        final zip = ZipDecoder().decodeBytes(original);
        if (version) {
          final m = jsonDecode(
            utf8.decode(zip.findFile('manifest.json')!.content),
          );
          m['format_version'] = 999;
          zip.add(
            ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(m))),
          );
        } else {
          zip.add(ArchiveFile.bytes('spoilers/0.bin', Uint8List(3)));
        }
        expect(
          () => prepareRestore(ZipEncoder().encodeBytes(zip), false, tmp.path),
          throwsFormatException,
        );
        expect(source.decks().length, 2);
      }
    },
  );
  test('restore write failure rolls back the prior data', () {
    final plan = prepareRestore(
      createBackup(path, false, '1'),
      false,
      tmp.path,
    );
    source.createDeck('Keep');
    source.db.execute(
      "CREATE TRIGGER reject BEFORE INSERT ON decks BEGIN SELECT RAISE(ABORT,'fail'); END",
    );
    expect(() => applyRestore(source, plan), throwsA(isA<SqliteException>()));
    expect(source.decks().length, 3);
    expect(source.thumbnailGrid, true);
  });
}
