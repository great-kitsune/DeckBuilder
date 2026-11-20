import 'dart:isolate';
import 'package:sqlite3/sqlite3.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog.dart';
import 'sync.dart';

const catalogTask = 'catalog-download';
Future<void> downloadInWorker(String path, InstallMode mode) async {
  final catalog = Catalog(sqlite3.open(path));
  void report(String text) => catalog.setMetadata('downloadStatus', text);
  try {
    await updateCatalog(path, report, mode: mode);
    report('설치 완료');
  } catch (e) {
    report('업데이트 실패 · $e');
    rethrow;
  } finally {
    catalog.db.close();
  }
}

Future<void> downloadOnDesktop(String path, InstallMode mode) =>
    Isolate.run(() => downloadInWorker(path, mode));

@pragma('vm:entry-point')
void catalogDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != catalogTask) return true;
    // Jobs queued by the previous app version only requested text.
    final mode = data?['mode'] == 'full' ? InstallMode.full : InstallMode.text;
    await downloadInWorker(data!['path'] as String, mode);
    return true;
  });
}
