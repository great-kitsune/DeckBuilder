import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'catalog.dart';
import 'backup_service.dart';

Future<Uint8List> _snapshot(String path, bool full, String version) =>
    Isolate.run(() => createBackup(path, full, version));

Future<BackupPreview> _preview(Uint8List bytes, bool full, String scratch) =>
    Isolate.run(() => prepareRestore(bytes, full, scratch));

class BackupView extends StatefulWidget {
  final Catalog catalog;
  final String path;
  final FutureOr<void> Function() onRestored;
  const BackupView(this.catalog, this.path, this.onRestored, {super.key});
  @override
  State<BackupView> createState() => _BackupViewState();
}

class _BackupViewState extends State<BackupView> {
  bool busy = false;
  String message = '';
  Future<bool> export(bool full, {bool recovery = false}) async {
    final info = await PackageInfo.fromPlatform();
    final version = '${info.version}+${info.buildNumber}';
    final path = widget.path;
    final bytes = await _snapshot(path, full, version);
    if (!mounted) return false;
    final file = await FilePicker.platform.saveFile(
      dialogTitle: recovery ? '교체 전 복구용 백업 저장' : '백업 저장',
      fileName:
          '${recovery ? 'recovery' : 'backup'}-${full ? 'full' : 'user'}-${DateTime.now().millisecondsSinceEpoch}.deckbuilder-backup.zip',
      type: FileType.custom,
      allowedExtensions: ['zip'],
      bytes: bytes,
    );
    return file != null;
  }

  Future<void> restore(bool full) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '백업 ZIP',
          extensions: ['zip'],
          mimeTypes: ['application/zip', 'application/octet-stream'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > backupByteLimit) {
      throw const FormatException('백업 파일이 너무 큽니다.');
    }
    final Uint8List bytes = await file.readAsBytes();
    final scratch = await Directory.systemTemp.createTemp('deck-restore-');
    try {
      final plan = await _preview(bytes, full, scratch.path);
      if (!mounted) return;
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(full ? '전체 DB 교체 복원' : '사용자 데이터 교체 복원'),
          content: Text(
            '복원할 덱 ${plan.decks}개 · 덱 항목 ${plan.entries}개 · 스포일러 ${plan.spoilers}개\n\n'
            '${full ? '공식 DB와 사용자 데이터' : '덱, 스포일러 및 사용자 설정'}를 교체합니다. 계속하면 현재 데이터의 복구용 ZIP을 먼저 저장합니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('백업 후 복원'),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return;
      final lock = await File(
        '${widget.path}.sync-lock',
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        final revision = widget.catalog.db
            .select('PRAGMA data_version')
            .single
            .values
            .first;
        if (!await export(full, recovery: true) || !mounted) return;
        if (widget.catalog.db
                .select('PRAGMA data_version')
                .single
                .values
                .first !=
            revision) {
          throw StateError('저장 중 DB가 변경되었습니다. 다시 시도하세요.');
        }
        applyRestore(widget.catalog, plan);
        await widget.onRestored();
        message = '복원을 완료했습니다.';
      } finally {
        await lock.close();
      }
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<void> run(bool full, bool importing) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      if (importing) {
        await restore(full);
      } else if (await export(full)) {
        message = '백업을 저장했습니다.';
      }
    } catch (e) {
      message = '작업 실패 · $e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('데이터 관리')),
      body: SafeArea(
        child: ListView(
          children: [
            for (final full in [false, true])
              for (final importing in [false, true])
                ListTile(
                  title: Text(
                    '${full ? '전체 DB' : '사용자 데이터'} ${importing ? '복원' : '백업'}',
                  ),
                  onTap: busy ? null : () => run(full, importing),
                ),
            if (busy) const LinearProgressIndicator(),
            if (message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(message),
              ),
          ],
        ),
      ),
    ),
  );
}
