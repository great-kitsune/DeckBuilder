import 'package:deck_builder/catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'v1 migration preserves preferences and decks; queue is unique and history bounded',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      final original = Catalog(db);
      original.createDeck('same');
      original.setMetadata('graphicsTheme', 'saved');
      db.execute(
        'DROP TABLE sync_events; DROP TABLE sync_jobs; DROP TABLE sync_state; DROP TABLE sync_index; PRAGMA user_version=1',
      );
      final c = Catalog(db);
      Catalog(db);
      expect(db.userVersion, catalogSchemaVersion);
      expect(c.decks().single.name, 'same');
      expect(c.metadata('graphicsTheme'), 'saved');
      for (var i = 0; i < 55; i++) {
        final id = c.queueSync(SyncMode.full);
        expect(c.queueSync(SyncMode.incremental), id);
        c.progress(id, SyncPhase.fetching_details, 2, 5);
        expect(c.pendingJob!['completed'], 2);
        c.endSync(id, SyncStatus.failed, code: 'invalid_response');
      }
      expect(c.syncHistory.length, 50);
      expect(c.baseline, isNull);
    },
  );
}
