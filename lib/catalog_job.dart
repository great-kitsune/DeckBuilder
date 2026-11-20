import 'dart:isolate';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:workmanager/workmanager.dart';
import 'catalog.dart';
import 'sync.dart';

const catalogTask = 'catalog-download';
bool hasWifiOnlyRoute(List<ConnectivityResult> routes) =>
    routes.isNotEmpty && routes.every((r) => r == ConnectivityResult.wifi);

Future<void> downloadInWorker(String path, {RootIsolateToken? root}) async {
  if (root != null) BackgroundIsolateBinaryMessenger.ensureInitialized(root);
  final catalog = Catalog(sqlite3.open(path));
  void report(String text) => catalog.setMetadata('downloadStatus', text);
  try {
    report('카드 목록 확인 중');
    await updateCatalog(
      path,
      report,
      networkAllowed: () async =>
          !catalog.wifiOnly ||
          hasWifiOnlyRoute(await Connectivity().checkConnectivity()),
    );
    report('업데이트 완료');
  } on WifiRequired {
    report('Wi-Fi 연결 대기 중');
    rethrow;
  } catch (e) {
    report('업데이트 실패 · $e');
    rethrow;
  } finally {
    catalog.db.close();
  }
}

Future<void> downloadOnDesktop(String path) {
  final token = RootIsolateToken.instance!;
  return Isolate.run(() => downloadInWorker(path, root: token));
}

@pragma('vm:entry-point')
void catalogDispatcher() {
  Workmanager().executeTask((task, data) async {
    if (task != catalogTask) return true;
    try {
      await downloadInWorker(data!['path'] as String);
      return true;
    } on WifiRequired {
      // Android reschedules the same user-requested job with backoff.
      return false;
    }
  });
}
