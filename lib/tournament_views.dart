import 'package:flutter/material.dart';
import 'catalog.dart';
import 'round_view.dart';

Future<T?> eventPage<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

Future<bool> confirmRemoval(BuildContext context, String label) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$label 삭제'),
        content: Text('$label 기록을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    ) ??
    false;

class TournamentList extends StatefulWidget {
  final Catalog catalog;
  const TournamentList(this.catalog, {super.key});
  @override
  State<TournamentList> createState() => _TournamentListState();
}

class _TournamentListState extends State<TournamentList> {
  Future<void> open(String id) async {
    await eventPage(context, TournamentDetail(widget.catalog, id));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.catalog.events;
    return Scaffold(
      appBar: AppBar(
        title: const Text('대회 기록'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('대회 생성'),
            onPressed: () async {
              final id = await eventPage<String>(
                context,
                EventForm(widget.catalog),
              );
              if (id != null && mounted) await open(id);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: rows.isEmpty
            ? const Center(child: Text('아직 기록한 대회가 없습니다.'))
            : ListView(
                children: [
                  for (final r in rows)
                    ListTile(
                      title: Text(r['name']),
                      subtitle: Text(
                        [
                          r['event_date'],
                          r['format'].toString().toUpperCase(),
                          snapshotName(r) ?? '덱 미지정',
                          r['status'] == 'active' ? '진행 중' : '종료',
                        ].join(' · '),
                      ),
                      onTap: () => open(r['id']),
                    ),
                ],
              ),
      ),
    );
  }
}

class EventForm extends StatefulWidget {
  final Catalog catalog;
  final String? id;
  const EventForm(this.catalog, {this.id, super.key});
  @override
  State<EventForm> createState() => _EventFormState();
}

class _EventFormState extends State<EventForm> {
  late final old = widget.id == null ? null : widget.catalog.event(widget.id!);
  late String name = old?['name'] ?? '',
      notes = old?['notes'] ?? '',
      format = old?['format'] ?? 'bo1';
  late DateTime date = old == null
      ? DateTime.now()
      : DateTime.parse(old!['event_date']);
  late int? deck = old?['deck_id'];
  bool forget = false;
  final form = GlobalKey<FormState>();
  @override
  Widget build(BuildContext context) {
    final locked =
        widget.id != null && widget.catalog.rounds(widget.id!).isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? '대회 생성' : '대회 수정')),
      body: SafeArea(
        child: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                initialValue: name,
                decoration: const InputDecoration(labelText: '대회 이름'),
                onChanged: (v) => name = v,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? '이름을 입력하세요.' : null,
              ),
              ListTile(
                title: const Text('대회 날짜'),
                subtitle: Text(eventDay(date)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(1900),
                    lastDate: DateTime(2200),
                  );
                  if (picked != null && mounted) setState(() => date = picked);
                },
              ),
              DropdownButtonFormField<String>(
                initialValue: format,
                decoration: InputDecoration(
                  labelText: '대회 유형',
                  helperText: locked ? '라운드를 모두 삭제하면 변경할 수 있습니다.' : null,
                ),
                items: [
                  for (final f in ['bo1', 'bo3'])
                    DropdownMenuItem(value: f, child: Text(f.toUpperCase())),
                ],
                onChanged: locked ? null : (v) => setState(() => format = v!),
              ),
              DropdownButtonFormField<int>(
                initialValue: deck ?? 0,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '사용 덱'),
                items: [
                  DropdownMenuItem(
                    value: 0,
                    child: Text(
                      old != null && old!['deck_id'] == null && !forget
                          ? snapshotName(old!) ?? '선택 안 함'
                          : '선택 안 함',
                    ),
                  ),
                  for (final d in widget.catalog.decks())
                    DropdownMenuItem(value: d.id, child: Text(d.name)),
                ],
                onChanged: (v) => setState(() {
                  deck = v == 0 ? null : v;
                  forget = deck == null;
                }),
              ),
              TextFormField(
                initialValue: notes,
                decoration: const InputDecoration(labelText: '대회 메모'),
                maxLines: 3,
                onChanged: (v) => notes = v,
              ),
              FilledButton(
                onPressed: () {
                  if (!form.currentState!.validate()) return;
                  final id = widget.catalog.saveEvent(
                    id: widget.id,
                    name: name,
                    date: eventDay(date),
                    format: format,
                    deck: deck,
                    notes: notes,
                    forgetDeck: forget,
                  );
                  Navigator.pop(context, id);
                },
                child: const Text('저장'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TournamentDetail extends StatefulWidget {
  final Catalog catalog;
  final String id;
  const TournamentDetail(this.catalog, this.id, {super.key});
  @override
  State<TournamentDetail> createState() => _TournamentDetailState();
}

class _TournamentDetailState extends State<TournamentDetail> {
  Future<void> editRound(String id) async {
    await eventPage(context, RoundView(widget.catalog, id));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.catalog,
        r = c.event(widget.id),
        rounds = c.rounds(widget.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(r['name']),
        actions: [
          IconButton(
            tooltip: '대회 수정',
            icon: const Icon(Icons.edit),
            onPressed: () async {
              await eventPage(context, EventForm(c, id: widget.id));
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '대회 삭제',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirmRemoval(context, '대회') && context.mounted) {
                c.deleteEvent(widget.id);
                Navigator.pop(context);
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              [
                r['event_date'],
                r['format'].toString().toUpperCase(),
                snapshotName(r) ?? '덱 미지정',
              ].join(' · '),
            ),
            if (r['notes'] != '') Text(r['notes']),
            for (final stage in ['swiss', 'top_cut']) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  stage == 'swiss' ? 'Swiss' : 'Top Cut',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final round in rounds.where((r) => r['stage'] == stage))
                ListTile(
                  title: Text(
                    [
                      '라운드 ${round['round_number']}',
                      if (stage == 'top_cut') cutStages[round['top_cut_stage']],
                      if (round['opponent_name'] != '') round['opponent_name'],
                    ].join(' · '),
                  ),
                  subtitle: Text(
                    round['status'] == 'completed'
                        ? matchResults[round['result']]!
                        : '진행 중',
                  ),
                  onTap: () => editRound(round['id']),
                ),
            ],
            FilledButton.icon(
              onPressed: () => editRound(c.addRound(widget.id)),
              icon: const Icon(Icons.add),
              label: const Text('라운드 추가'),
            ),
          ],
        ),
      ),
    );
  }
}
