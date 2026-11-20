import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'catalog.dart';
import 'card_image.dart';
import 'search_view.dart';
import 'spoiler.dart';
import 'catalog_job.dart';
import 'sync.dart';
import 'package:workmanager/workmanager.dart';

void main() => runApp(const DeckBuilder());

class DeckBuilder extends StatelessWidget {
  const DeckBuilder({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Grand Archive Utility',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff31585b),
      useMaterial3: true,
    ),
    home: const Library(),
  );
}

class Library extends StatefulWidget {
  const Library({super.key});
  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  Catalog? store;
  late String path;
  int tab = 0, revision = 0;
  bool busy = false;
  String status = '';
  Timer? progressTimer;
  bool checking = false;
  String? lastUpdated;
  bool lastOffline = false, lastComplete = false;
  @override
  void initState() {
    super.initState();
    open();
  }

  Future<void> open() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      path = '${dir.path}${Platform.pathSeparator}catalog.sqlite';
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode=WAL');
      final library = Catalog(db);
      if (Platform.isAndroid) {
        await Workmanager().initialize(catalogDispatcher);
        busy = await Workmanager().isScheduledByUniqueName(catalogTask);
      }
      lastUpdated = library.updated;
      lastOffline = library.useOfflineImages;
      lastComplete = library.imagesComplete;
      if (!mounted) {
        db.close();
        return;
      }
      setState(() {
        store = library;
        status = busy
            ? (library.metadata('downloadStatus') ?? '다운로드 대기 중')
            : '';
      });
      if (busy) watchProgress();
    } catch (e) {
      if (mounted) setState(() => status = 'DB 열기 실패 · $e');
    }
  }

  Future<void> update() async {
    if (busy) return;
    final mode = await showDialog<InstallMode>(
      context: context,
      builder: (_) => InstallDialog(
        hasText: store!.updated != null,
        hasImages: store!.imagesComplete,
        offlineRequested: store!.useOfflineImages,
      ),
    );
    if (!mounted || mode == null || busy) return;
    setState(() {
      busy = true;
      status = '설치 준비 중';
    });
    final catalog = store!;
    try {
      catalog.setMetadata('downloadStatus', '다운로드 대기 중');
      if (Platform.isAndroid) {
        await Workmanager().registerOneOffTask(
          catalogTask,
          catalogTask,
          inputData: {'path': path, 'mode': mode.name},
          foregroundServiceConfig: mode == InstallMode.full
              ? ForegroundServiceConfig(
                  notificationTitle: 'Grand Archive Utility',
                  notificationText: '카드 이미지 설치 중',
                )
              : null,
          existingWorkPolicy: ExistingWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
        if (mounted) watchProgress();
      } else {
        watchProgress();
        await downloadOnDesktop(path, mode);
        if (mounted) finishDownload();
      }
    } catch (e) {
      if (mounted) {
        finishDownload();
        setState(() {
          status = '다운로드 중단 · $e';
        });
      }
    }
  }

  void finishDownload() {
    progressTimer?.cancel();
    final catalog = store!;
    final updated = catalog.updated;
    setState(() {
      if (updated != lastUpdated ||
          catalog.useOfflineImages != lastOffline ||
          catalog.imagesComplete != lastComplete) {
        revision++;
      }
      lastOffline = catalog.useOfflineImages;
      lastComplete = catalog.imagesComplete;
      lastUpdated = updated;
      busy = false;
      status = catalog.metadata('downloadStatus') ?? '';
    });
  }

  void watchProgress() {
    progressTimer?.cancel();
    progressTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (checking || !mounted) return;
      checking = true;
      try {
        if (Platform.isAndroid &&
            !await Workmanager().isScheduledByUniqueName(catalogTask)) {
          if (mounted) finishDownload();
          return;
        }
        if (mounted) {
          final message = store!.metadata('downloadStatus') ?? '다운로드 대기 중';
          if (status != message) setState(() => status = message);
        }
      } catch (e) {
        if (mounted) setState(() => status = '진행 상태 확인 실패 · $e');
      } finally {
        checking = false;
      }
    });
  }

  Future<void> manageCache() async {
    try {
      final bytes = await cacheBytes();
      if (!mounted) return;
      final clear = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('이미지 캐시'),
          content: Text(
            '저장된 카드 이미지 · ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('캐시 삭제'),
            ),
          ],
        ),
      );
      if (clear == true) await clearCardImages();
    } on FileSystemException catch (e) {
      if (mounted) setState(() => status = '이미지 캐시 오류 · $e');
    }
  }

  @override
  void dispose() {
    progressTimer?.cancel();
    store?.db.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = store;
    if (library == null) {
      return Scaffold(
        body: Center(
          child: status.isEmpty
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(status),
                    TextButton(onPressed: open, child: const Text('다시 열기')),
                  ],
                ),
        ),
      );
    }
    const names = ['홈', '카드 검색', '설정'];
    const icons = [Icons.home_outlined, Icons.search, Icons.settings_outlined];
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final syncAction = FilledButton.icon(
      onPressed: busy ? null : update,
      icon: const Icon(Icons.sync),
      label: Text(library.updated == null ? '데이터베이스 다운로드' : '데이터베이스 업데이트'),
    );
    return Scaffold(
      appBar: AppBar(title: Text(names[tab])),
      body: Row(
        children: [
          if (wide)
            NavigationRail(
              selectedIndex: tab,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: [
                for (var i = 0; i < 3; i++)
                  NavigationRailDestination(
                    icon: Icon(icons[i]),
                    label: Text(names[i]),
                  ),
              ],
            ),
          Expanded(
            child: Column(
              children: [
                if (busy) const LinearProgressIndicator(),
                if (status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(status),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: tab,
                    children: [
                      ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            'Grand Archive Utility',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 12),
                          syncAction,
                          ListTile(
                            leading: const Icon(Icons.search),
                            title: const Text('카드 검색'),
                            onTap: () => setState(() => tab = 1),
                          ),
                        ],
                      ),
                      SearchView(
                        library,
                        revision: revision,
                        onAdd: () async {
                          final saved = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SpoilerForm(library),
                            ),
                          );
                          if (saved == true && mounted) {
                            setState(() => revision++);
                          }
                        },
                      ),
                      ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          ListTile(
                            title: const Text('마지막 업데이트'),
                            subtitle: Text(library.updated ?? '설치 전'),
                          ),
                          ListTile(
                            title: const Text('설치 상태'),
                            subtitle: Text(
                              library.updated == null
                                  ? '설치 전'
                                  : library.imagesComplete
                                  ? '텍스트 + 이미지'
                                  : '텍스트 설치됨 · 전체 이미지 추가 가능',
                            ),
                          ),
                          ListTile(
                            title: const Text('카드 검색 표시 방식'),
                            subtitle: SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('목록')),
                                ButtonSegment(value: true, label: Text('썸네일')),
                              ],
                              selected: {library.thumbnailGrid},
                              onSelectionChanged: (v) => setState(
                                () => library.setMetadata(
                                  'thumbnailGrid',
                                  v.single ? '1' : '0',
                                ),
                              ),
                            ),
                          ),
                          syncAction,
                          ListTile(
                            title: const Text('이전 버전 이미지 캐시 관리'),
                            onTap: manageCache,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (v) => setState(() => tab = v),
              destinations: [
                for (var i = 0; i < 3; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: names[i]),
              ],
            ),
    );
  }
}

class InstallDialog extends StatefulWidget {
  final bool hasText, hasImages, offlineRequested;
  const InstallDialog({
    super.key,
    required this.hasText,
    required this.hasImages,
    required this.offlineRequested,
  });
  @override
  State<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<InstallDialog> {
  late InstallMode mode = widget.offlineRequested
      ? InstallMode.full
      : InstallMode.text;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('카드 데이터베이스 설치 방식'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RadioGroup<InstallMode>(
            groupValue: mode,
            onChanged: (v) => setState(() => mode = v!),
            child: Column(
              children: [
                RadioListTile(
                  value: InstallMode.text,
                  title: const Text('텍스트만 설치'),
                  subtitle: Text(
                    widget.offlineRequested
                        ? '설치한 공식 이미지를 삭제하고 열람할 때 API에서 불러옵니다.'
                        : '카드 이미지는 열람할 때 공식 API에서 불러옵니다.',
                  ),
                ),
                RadioListTile(
                  value: InstallMode.full,
                  title: const Text('텍스트 + 이미지 모두 설치'),
                  subtitle: Text(
                    widget.hasText && !widget.hasImages
                        ? '설치된 텍스트는 유지하고 오프라인 이미지만 추가합니다.'
                        : '카드 이미지까지 저장해 오프라인에서 열람합니다.',
                  ),
                ),
              ],
            ),
          ),
          const Text('모바일 데이터와 기기 저장 공간을 사용합니다. 전체 이미지 설치에는 시간이 걸릴 수 있습니다.'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, mode),
        child: const Text('확인'),
      ),
    ],
  );
}
