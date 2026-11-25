import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog.dart';
import 'sync.dart';

const catalogTask = 'catalog-download';
Future<void> downloadInWorker(String path, [String? id]) =>
    updateCatalog(path, (_) {}, jobId: id);

Future<void> downloadOnDesktop(String path, [String? id]) =>
    Isolate.run(() => downloadInWorker(path, id));

@pragma('vm:entry-point')
void catalogDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != catalogTask) return true;
    await downloadInWorker(data!['path'] as String, data['id'] as String?);
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
