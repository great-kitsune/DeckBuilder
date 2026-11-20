import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog.dart';
import 'sync.dart';

const catalogTask = 'catalog-download';
Future<void> downloadInWorker(String path) async {
  final catalog = Catalog(sqlite3.open(path));
  void report(String text) => catalog.setMetadata('downloadStatus', text);
  try {
    await updateCatalog(path, report);
    report('설치 완료');
  } catch (e) {
    report('업데이트 실패 · $e');
    rethrow;
  } finally {
    catalog.db.close();
  }
}

Future<void> downloadOnDesktop(String path) =>
    Isolate.run(() => downloadInWorker(path));

@pragma('vm:entry-point')
void catalogDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != catalogTask) return true;
    await downloadInWorker(data!['path'] as String);
    return true;
  });
}

Future<IntegrityResult> inspectCatalogFile(String path) => Isolate.run(() {
  final db = sqlite3.open(path);
  try {
    return Catalog(db).inspect();
  } finally {
    db.close();
  }
});
