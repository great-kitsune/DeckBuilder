import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'catalog.dart';
import 'deck_editor.dart';
import 'card_image.dart';
import 'search_view.dart';
import 'spoiler.dart';
import 'catalog_job.dart';
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
  int tab = 0;
  final revision = ValueNotifier(0);
  bool busy = false;
  String status = '';
  Timer? progressTimer;
  bool checking = false;
  String? lastUpdated;
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => InstallDialog(installed: store!.updated != null),
    );
    if (!mounted || confirmed != true || busy) return;
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
          inputData: {'path': path},
          existingWorkPolicy: ExistingWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
        if (mounted) watchProgress();
      } else {
        watchProgress();
        await downloadOnDesktop(path);
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
      if (updated != lastUpdated) revision.value++;
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

  Future<void> checkIntegrity() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '무결성 검사 중';
    });
    try {
      final result = await inspectCatalogFile(path);
      final damagedImages = await removeDamagedImages();
      if (!mounted) return;
      setState(() => revision.value++);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('무결성 검사 결과'),
          content: Text(
            [
              if (result.hasManifest)
                '누락된 텍스트 레코드 · ${result.missing}건'
              else
                '이전 설치본에는 공식 목록 대조 기준이 없습니다. 재설치하면 누락 건수도 확인할 수 있습니다.',
              '데이터 손상 · ${result.damaged}건',
              '공식 카드로 교체 · ${result.replaced}건',
              '손상된 이미지 캐시 정리 · $damagedImages개',
              if (damagedImages > 0) '해당 이미지는 다음 열람 때 다시 받습니다.',
            ].join('\n'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
      if (mounted) setState(() => status = '무결성 검사 완료');
    } catch (e) {
      if (mounted) setState(() => status = '무결성 검사 실패 · $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
    revision.dispose();
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
    const names = ['홈', '카드 검색', '덱', '설정'];
    const icons = [
      Icons.home_outlined,
      Icons.search,
      Icons.style_outlined,
      Icons.settings_outlined,
    ];
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final syncAction = FilledButton.icon(
      onPressed: busy ? null : update,
      icon: const Icon(Icons.sync),
      label: Text(library.updated == null ? '텍스트만 다운로드' : '재설치'),
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
                for (var i = 0; i < names.length; i++)
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
                        revision: revision.value,
                        onAdd: () async {
                          final saved = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => SpoilerForm(library),
                            ),
                          );
                          if (saved == true && mounted) {
                            setState(() => revision.value++);
                          }
                        },
                      ),
                      DeckList(
                        library,
                        catalogRevision: revision,
                        onCatalogChange: () => setState(() => revision.value++),
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
                                  : '텍스트 설치됨 · 이미지 열람 시 캐시',
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
                            leading: const Icon(Icons.fact_check_outlined),
                            title: const Text('무결성 검사'),
                            onTap: busy || library.updated == null
                                ? null
                                : checkIntegrity,
                          ),
                          for (final local in library.db.select(
                            'SELECT id,name FROM spoiler_cards WHERE active=2 ORDER BY name',
                          ))
                            ListTile(
                              title: Text('공식 카드 선택 대기 · ${local['name']}'),
                              onTap: busy
                                  ? null
                                  : () async {
                                      await Navigator.push(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) => CardDetail(
                                            library,
                                            local['id'] as String,
                                            null,
                                          ),
                                        ),
                                      );
                                      if (mounted) {
                                        setState(() => revision.value++);
                                      }
                                    },
                            ),
                          ListTile(
                            title: const Text('이미지 캐시 관리'),
                            onTap: busy ? null : manageCache,
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
                for (var i = 0; i < names.length; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: names[i]),
              ],
            ),
    );
  }
}

class InstallDialog extends StatelessWidget {
  final bool installed;
  const InstallDialog({required this.installed, super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(installed ? '데이터베이스 재설치' : '텍스트만 다운로드'),
    content: const Text(
      '공식 카드와 인쇄판 정보를 다운로드합니다. 모바일 데이터가 사용될 수 있습니다. 이미지는 열람할 때 받아 저장합니다.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: const Text('확인'),
      ),
    ],
  );
}
