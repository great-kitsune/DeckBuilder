// ignore_for_file: constant_identifier_names

part of 'catalog.dart';

enum SyncMode { initial, incremental, full }

enum SyncStatus {
  queued,
  running,
  paused,
  interrupted,
  failed,
  completed,
  cancelled,
}

enum SyncPhase {
  checking,
  fetching_index,
  fetching_changes,
  fetching_card_changes,
  fetching_edition_changes,
  fetching_details,
  validating,
  applying,
  finished,
}

String syncNow() => DateTime.now().toUtc().toIso8601String();
const pendingSync = "status IN ('queued','running','paused','interrupted')";

void createSyncSchema(Database db) {
  db.execute('''
    CREATE TABLE IF NOT EXISTS sync_jobs(
      id TEXT PRIMARY KEY, mode TEXT NOT NULL, status TEXT NOT NULL,
      phase TEXT NOT NULL DEFAULT 'checking', completed INTEGER NOT NULL DEFAULT 0,
      total INTEGER, started_at TEXT NOT NULL, updated_at TEXT NOT NULL, finished_at TEXT,
      checkpoint TEXT, error_code TEXT, error_message TEXT, requests INTEGER NOT NULL DEFAULT 0,
      bytes INTEGER NOT NULL DEFAULT 0, fallback INTEGER NOT NULL DEFAULT 0,
      added_cards INTEGER NOT NULL DEFAULT 0, changed_cards INTEGER NOT NULL DEFAULT 0,
      added_editions INTEGER NOT NULL DEFAULT 0, changed_editions INTEGER NOT NULL DEFAULT 0,
      removed_cards INTEGER NOT NULL DEFAULT 0, apply_ms INTEGER NOT NULL DEFAULT 0);
    CREATE UNIQUE INDEX IF NOT EXISTS single_pending_sync ON sync_jobs((1)) WHERE $pendingSync;
    CREATE TABLE IF NOT EXISTS sync_events(job TEXT REFERENCES sync_jobs(id) ON DELETE CASCADE,
      at TEXT NOT NULL, phase TEXT NOT NULL, code TEXT);
    CREATE TABLE IF NOT EXISTS sync_state(id INTEGER PRIMARY KEY CHECK(id=1),
      last_successful_sync TEXT NOT NULL, last_full TEXT, index_hash TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS sync_index(id TEXT PRIMARY KEY,slug TEXT NOT NULL);
  ''');
}

extension SyncState on Catalog {
  String newUuid() =>
      db.select(
            """SELECT lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-4'||
        substr(hex(randomblob(2)),2)||'-'||substr('89ab',(random() & 3)+1,1)||
        substr(hex(randomblob(2)),2)||'-'||hex(randomblob(6))) AS id""",
          ).single['id']
          as String;
  Row? get pendingJob =>
      db.select('SELECT * FROM sync_jobs WHERE $pendingSync').firstOrNull;
  Row? job(String id) =>
      db.select('SELECT * FROM sync_jobs WHERE id=?', [id]).firstOrNull;
  Row? get baseline => db.select('SELECT * FROM sync_state').firstOrNull;
  List<Row> get syncHistory =>
      db.select('SELECT * FROM sync_jobs ORDER BY rowid DESC LIMIT 51');
  String queueSync(SyncMode mode) {
    late String id;
    transaction(() {
      final existing = pendingJob;
      if (existing != null) {
        id = existing['id'] as String;
        return;
      }
      final now = syncNow();
      id = newUuid();
      db.execute(
        "INSERT INTO sync_jobs(id,mode,status,started_at,updated_at) VALUES(?,?,'queued',?,?)",
        [id, mode.name, now, now],
      );
    });
    return id;
  }

  void progress(String id, SyncPhase phase, int completed, int? total) {
    final previous = job(id);
    if (previous == null || previous['status'] == 'cancelled') return;
    final now = syncNow();
    db.execute(
      "UPDATE sync_jobs SET status='running',phase=?,completed=?,total=?,updated_at=? WHERE id=? AND $pendingSync",
      [phase.name, completed, total, now, id],
    );
    if (previous['phase'] != phase.name || previous['status'] != 'running') {
      db.execute('INSERT INTO sync_events VALUES(?,?,?,NULL)', [
        id,
        now,
        phase.name,
      ]);
    }
  }

  void endSync(String id, SyncStatus status, {String? code, String? message}) {
    final now = syncNow();
    final terminal = [
      SyncStatus.completed,
      SyncStatus.failed,
      SyncStatus.cancelled,
    ].contains(status);
    db.execute(
      "UPDATE sync_jobs SET status=?,phase=CASE WHEN ? THEN 'finished' ELSE phase END,finished_at=?,updated_at=?,error_code=?,error_message=?,checkpoint=CASE WHEN ? THEN NULL ELSE checkpoint END WHERE id=? AND $pendingSync",
      [
        status.name,
        terminal,
        terminal ? now : null,
        now,
        code,
        message,
        terminal,
        id,
      ],
    );
    if (db.updatedRows == 0) return;
    db.execute('INSERT INTO sync_events VALUES(?,?,?,?)', [
      id,
      now,
      status.name,
      code,
    ]);
    db.execute(
      'DELETE FROM sync_jobs WHERE NOT ($pendingSync) AND id NOT IN (SELECT id FROM sync_jobs WHERE NOT ($pendingSync) ORDER BY rowid DESC LIMIT 50)',
    );
  }

  void invalidateSyncBaseline() {
    final pending = pendingJob;
    if (pending != null) {
      endSync(
        pending['id'] as String,
        SyncStatus.cancelled,
        code: 'cancelled',
        message: '전체 DB 복원으로 이전 작업을 종료했습니다.',
      );
    }
    db.execute('DELETE FROM sync_index; DELETE FROM sync_state;');
  }
}
