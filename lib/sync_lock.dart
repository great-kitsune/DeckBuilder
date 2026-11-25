import 'dart:io';
import 'package:sqlite3/sqlite3.dart';

// POSIX file locks alone are process-scoped. The auxiliary SQLite writer
// also excludes other isolates/connections in the same process.
class SyncLock {
  final Database guard;
  final RandomAccessFile file;
  SyncLock._(this.guard, this.file);
  static Future<SyncLock?> acquire(String path) async {
    final guard = sqlite3.open('$path.sync-guard');
    try {
      guard.execute('BEGIN IMMEDIATE');
    } on SqliteException catch (e) {
      guard.close();
      if (e.resultCode == 5 || e.resultCode == 6) return null;
      rethrow;
    }
    RandomAccessFile? file;
    try {
      file = await File('$path.sync-lock').open(mode: FileMode.append);
      await file.lock(FileLock.exclusive);
      return SyncLock._(guard, file);
    } catch (_) {
      await file?.close();
      guard.close();
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      await file.close();
    } finally {
      guard.close();
    }
  }
}
