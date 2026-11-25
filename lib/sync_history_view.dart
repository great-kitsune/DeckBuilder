import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' as sql show Row;
import 'catalog.dart';
import 'sync_labels.dart';

String syncTime(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  return date == null ? '—' : date.toString().substring(0, 19);
}

class SyncHistoryView extends StatelessWidget {
  final Catalog catalog;
  const SyncHistoryView(this.catalog, {super.key});
  @override
  Widget build(BuildContext context) {
    final jobs = catalog.syncHistory;
    return Scaffold(
      appBar: AppBar(title: const Text('동기화 기록')),
      body: jobs.isEmpty
          ? const Center(child: Text('아직 동기화 기록이 없습니다.'))
          : ListView.builder(
              itemCount: jobs.length,
              itemBuilder: (_, i) {
                final job = jobs[i];
                return ListTile(
                  title: Text(
                    '${modeLabels[job['mode']]} · ${statusLabels[job['status']]}',
                  ),
                  subtitle: Text(syncTime(job['started_at'])),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SyncDetails(catalog, job['id'] as String),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class SyncDetails extends StatelessWidget {
  final Catalog catalog;
  final String id;
  const SyncDetails(this.catalog, this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final job = catalog.job(id);
    final start = DateTime.tryParse(job?['started_at']?.toString() ?? '');
    final end = DateTime.tryParse(job?['finished_at']?.toString() ?? '');
    return Scaffold(
      appBar: AppBar(title: const Text('동기화 상세')),
      body: job == null
          ? const Text('보관 기간이 지난 기록입니다.')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  jobLabel(job),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SelectableText(
                  [
                    '작업 ID · $id',
                    '시작 · ${syncTime(job['started_at'])}',
                    '마지막 상태 변경 · ${syncTime(job['updated_at'])}',
                    if (end != null && start != null)
                      '종료 · ${syncTime(job['finished_at'])}   소요 · ${end.difference(start).inMilliseconds} ms',
                    '공식 API 요청 · ${job['requests']}회   수신 · ${job['bytes']} B',
                    '신규 카드 · ${job['added_cards']}장   변경 카드 · ${job['changed_cards']}장',
                    '신규 인쇄판 · ${job['added_editions']}개   변경·제외 인쇄판 · ${job['changed_editions']}개',
                    '비활성 카드 · ${job['removed_cards']}장',
                    'DB 반영 · ${job['apply_ms']} ms',
                    if (job['fallback'] == 1) '전체 데이터 재검사로 전환',
                    if (job['error_code'] != null)
                      '오류 · ${job['error_code']}   ${job['error_message']}',
                  ].join('\n'),
                ),
                const Divider(),
                for (final event in catalog.db.select(
                  'SELECT * FROM sync_events WHERE job=? ORDER BY rowid',
                  [id],
                ))
                  Text(
                    '${syncTime(event['at'])} · ${phaseLabels[event['phase']] ?? statusLabels[event['phase']] ?? event['phase']}',
                  ),
              ],
            ),
    );
  }
}

class SyncControls extends StatefulWidget {
  final Catalog catalog;
  final Future<void> Function({bool full}) update;
  final Future<void> Function() inspect;
  final Future<void> Function(String) cancel;
  const SyncControls(
    this.catalog, {
    required this.update,
    required this.inspect,
    required this.cancel,
    super.key,
  });
  @override
  State<SyncControls> createState() => _SyncControlsState();
}

class _SyncControlsState extends State<SyncControls> {
  Timer? timer;
  sql.Row? job;
  bool submitting = false;
  void refresh() {
    final next = widget.catalog.db
        .select('SELECT * FROM sync_jobs ORDER BY rowid DESC LIMIT 1')
        .firstOrNull;
    if (next?['updated_at'] != job?['updated_at'] ||
        next?['status'] != job?['status']) {
      setState(() => job = next);
    }
  }

  @override
  void initState() {
    super.initState();
    refresh();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> perform(Future<void> Function() action) async {
    if (submitting) return;
    setState(() => submitting = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => submitting = false);
        refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = job;
    final installed = widget.catalog.updated != null;
    final active = ['queued', 'running'].contains(row?['status']);
    final resumable = ['paused', 'interrupted'].contains(row?['status']);
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.sync),
          title: Text(
            resumable
                ? '다운로드 재개'
                : installed
                ? '카드 데이터 업데이트'
                : '카드 데이터 설치',
          ),
          onTap: active || submitting
              ? null
              : () => perform(() => widget.update()),
        ),
        ListTile(
          leading: const Icon(Icons.refresh),
          title: const Text('전체 데이터 재검사'),
          subtitle: const Text('공식 카드와 인쇄판 전체를 다시 확인합니다.'),
          onTap: !installed || active || resumable || submitting
              ? null
              : () => perform(() => widget.update(full: true)),
        ),
        ListTile(
          title: const Text('다운로드 상태'),
          subtitle: Text(
            row == null
                ? '진행 중인 작업이 없습니다.'
                : '${jobLabel(row)}\n${syncTime(row['updated_at'])}',
          ),
          trailing:
              row != null &&
                  (active || resumable) &&
                  (resumable || row['phase'] != 'applying')
              ? TextButton(
                  onPressed: () => widget.cancel(row['id'] as String),
                  child: const Text('취소'),
                )
              : null,
        ),
        ListTile(
          title: const Text('동기화 기록'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => SyncHistoryView(widget.catalog)),
          ),
        ),
        ListTile(
          title: const Text('데이터 무결성 검사'),
          onTap: !installed || active || submitting
              ? null
              : () => perform(widget.inspect),
        ),
        const Divider(),
      ],
    );
  }
}
