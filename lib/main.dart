import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'catalog.dart';
import 'backup_view.dart';
import 'deck_editor.dart';
import 'tournament_views.dart';
import 'card_image.dart';
import 'search_view.dart';
import 'spoiler.dart';
import 'catalog_job.dart';
import 'sync.dart';
import 'sync_lock.dart';
import 'sync_labels.dart';
import 'sync_history_view.dart';
import 'package:workmanager/workmanager.dart';
import 'theme_repository.dart';
import 'theme_background.dart';
import 'theme_selection_view.dart';

void main() => runApp(const DeckBuilder());

class DeckBuilder extends StatefulWidget {
  const DeckBuilder({super.key});
  @override
  State<DeckBuilder> createState() => _DeckBuilderState();
}

class _DeckBuilderState extends State<DeckBuilder> {
  final selected = ValueNotifier<SelectedGraphic?>(null);
  @override
  void dispose() {
    selected.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<SelectedGraphic?>(
        valueListenable: selected,
        builder: (context, graphic, _) {
          final base = ThemeData(
            colorSchemeSeed: const Color(0xff31585b),
            useMaterial3: true,
            brightness: graphic == null ? Brightness.light : Brightness.dark,
          );
          return MaterialApp(
            title: 'Grand Archive Utility',
            theme: graphic == null
                ? base
                : base.copyWith(
                    scaffoldBackgroundColor: Colors.transparent,
                    appBarTheme: AppBarTheme(
                      backgroundColor: base.colorScheme.surface,
                    ),
                    listTileTheme: ListTileThemeData(
                      tileColor: base.colorScheme.surface.withValues(
                        alpha: .72,
                      ),
                    ),
                    inputDecorationTheme: InputDecorationTheme(
                      filled: true,
                      fillColor: base.colorScheme.surface,
                    ),
                  ),
            builder: (context, child) => Stack(
              fit: StackFit.expand,
              children: [
                if (graphic != null) ...[
                  ThemeBackground(graphic),
                  ColoredBox(
                    color: Colors.black.withValues(alpha: graphic.overlay),
                  ),
                ],
                child!,
              ],
            ),
            home: Library(selected),
          );
        },
      );
}

class Library extends StatefulWidget {
  final ValueNotifier<SelectedGraphic?> selected;
  const Library(this.selected, {super.key});
  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> with WidgetsBindingObserver {
  Catalog? store;
  late String path;
  int tab = 0;
  final revision = ValueNotifier(0);
  bool busy = false;
  String status = '';
  Timer? progressTimer;

  String? lastUpdated;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      }
      final initialTheme = await readGraphicTheme(library);
      lastUpdated = library.updated;
      if (!mounted) {
        db.close();
        return;
      }
      widget.selected.value = initialTheme;
      setState(() {
        store = library;
      });
      await recoverWorker();
      if (mounted) {
        readProgress();
        watchProgress();
      }
    } catch (e) {
      if (mounted) setState(() => status = 'DB 열기 실패 · $e');
    }
  }

  Future<void> recoverWorker() async {
    final catalog = store;
    final row = catalog?.pendingJob;
    if (catalog == null ||
        row == null ||
        !['queued', 'running'].contains(row['status'])) {
      return;
    }
    final id = row['id'] as String;
    if (Platform.isAndroid &&
        await Workmanager().isScheduledByUniqueName('$catalogTask-$id')) {
      return;
    }
    final lock = await SyncLock.acquire(path);
    if (lock == null) return;
    try {
      if (mounted && catalog.job(id)?['status'] == row['status']) {
        catalog.transaction(
          () => catalog.endSync(
            id,
            SyncStatus.interrupted,
            code: 'interrupted',
            message: '마지막 안전 지점부터 재개할 수 있습니다.',
          ),
        );
      }
    } finally {
      await lock.close();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && store != null) {
      unawaited(refreshWorkerOnResume());
    }
  }

  Future<void> refreshWorkerOnResume() async {
    try {
      await recoverWorker();
      if (mounted) readProgress();
    } catch (_) {
      if (mounted) setState(() => status = '다운로드 상태를 확인할 수 없습니다.');
    }
  }

  Future<void> update({bool full = false}) async {
    if (busy) return;
    final catalog = store!;
    final pending = catalog.pendingJob;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => InstallDialog(
        installed: catalog.updated != null,
        full: full,
        resume: pending != null,
      ),
    );
    if (!mounted || confirmed != true || busy) return;
    final mode = full
        ? SyncMode.full
        : catalog.updated == null
        ? SyncMode.initial
        : SyncMode.incremental;
    final guard = await SyncLock.acquire(path);
    if (guard == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('데이터 작업이 진행 중입니다.')));
      }
      return;
    }
    late String id;
    try {
      if (!mounted) return;
      id = catalog.queueSync(mode);
      catalog.db.execute(
        "UPDATE sync_jobs SET status='queued',error_code=NULL,error_message=NULL WHERE id=? AND status IN ('interrupted','paused')",
        [id],
      );
    } finally {
      await guard.close();
    }
    if (!mounted) return;
    readProgress();
    try {
      if (Platform.isAndroid) {
        await Workmanager().registerOneOffTask(
          '$catalogTask-$id',
          catalogTask,
          inputData: {'path': path, 'id': id},
          existingWorkPolicy: ExistingWorkPolicy.keep,
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        await downloadOnDesktop(path, id);
      }
    } catch (_) {
      if (!mounted) return;
      if (['queued', 'running'].contains(catalog.job(id)?['status'])) {
        await recoverWorker();
      }
    }
    if (mounted) readProgress();
  }

  String? lastJobStamp;
  void readProgress() {
    final catalog = store!;
    final row = catalog.db
        .select('SELECT * FROM sync_jobs ORDER BY rowid DESC LIMIT 1')
        .firstOrNull;
    final stamp = row == null
        ? null
        : "${row['id']}|${row['status']}|${row['updated_at']}";
    if (stamp == lastJobStamp) return;
    lastJobStamp = stamp;
    setState(() {
      if (catalog.updated != lastUpdated) {
        revision.value++;
        lastUpdated = catalog.updated;
      }
      busy = row != null && ['running', 'queued'].contains(row['status']);
      status = row == null ? '' : jobLabel(row);
    });
  }

  void watchProgress() {
    progressTimer?.cancel();
    progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) readProgress();
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
                '이전 설치본에는 공식 목록 대조 기준이 없습니다. 전체 데이터 재검사 후 누락 건수도 확인할 수 있습니다.',
              '데이터 손상 · ${result.damaged}건',
              if (result.damaged + result.missing > 0)
                '전체 데이터 재검사를 실행하세요. DB를 열 수 없으면 보관한 백업을 확인하세요.',
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
    WidgetsBinding.instance.removeObserver(this);
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
    final job = library.pendingJob;
    final syncAction = FilledButton.icon(
      onPressed: busy ? null : update,
      icon: const Icon(Icons.sync),
      label: Text(
        job != null && !busy
            ? '다운로드 재개'
            : library.updated == null
            ? '카드 데이터 설치'
            : '카드 데이터 업데이트',
      ),
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
                if (busy)
                  LinearProgressIndicator(
                    value:
                        job == null || job['total'] == null || job['total'] == 0
                        ? null
                        : (job['completed'] as int) / (job['total'] as int),
                  ),
                if (job != null &&
                    (job['phase'] != 'applying' || job['status'] != 'running'))
                  TextButton(
                    onPressed: () async {
                      await cancelSync(path, library, job['id'] as String);
                      if (mounted) readProgress();
                    },
                    child: const Text('다운로드 취소'),
                  ),
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
                            leading: const Icon(Icons.emoji_events_outlined),
                            title: const Text('대회 기록'),
                            onTap: () =>
                                eventPage(context, TournamentList(library)),
                          ),
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
                        onCatalogChange: () => setState(() => revision.value++),
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
                            title: const Text('테마 선택'),
                            onTap: busy
                                ? null
                                : () => Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ThemeSelectionView(
                                        library,
                                        widget.selected,
                                      ),
                                    ),
                                  ),
                          ),
                          ListTile(
                            title: const Text('데이터 관리'),
                            subtitle: const Text('업데이트 · 동기화 기록 · 백업과 복원'),
                            onTap: () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => BackupView(
                                  library,
                                  path,
                                  () async {
                                    final theme = await readGraphicTheme(
                                      library,
                                    );
                                    if (mounted) {
                                      widget.selected.value = theme;
                                    }
                                    if (mounted) {
                                      setState(() {
                                        lastUpdated = library.updated;
                                        status = '';
                                        revision.value++;
                                      });
                                    }
                                  },
                                  syncControls: SyncControls(
                                    library,
                                    update: update,
                                    inspect: checkIntegrity,
                                    cancel: (id) =>
                                        cancelSync(path, library, id),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const AppVersionTile(),
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
                                        MaterialPageRoute<bool>(
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
  final bool installed, full, resume;
  const InstallDialog({
    required this.installed,
    this.full = false,
    this.resume = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      resume
          ? '다운로드 재개'
          : full
          ? '전체 데이터 재검사'
          : installed
          ? '카드 데이터 업데이트'
          : '카드 데이터 설치',
    ),
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

class AppVersionTile extends StatefulWidget {
  const AppVersionTile({super.key});
  @override
  State<AppVersionTile> createState() => _AppVersionTileState();
}

class _AppVersionTileState extends State<AppVersionTile> {
  late final info = PackageInfo.fromPlatform();
  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: info,
    builder: (context, snapshot) => ListTile(
      title: const Text('앱 버전'),
      subtitle: Text(
        snapshot.data == null
            ? (snapshot.hasError ? '확인할 수 없습니다' : '확인 중…')
            : '${snapshot.data!.version} · 빌드 ${snapshot.data!.buildNumber}',
      ),
    ),
  );
}
