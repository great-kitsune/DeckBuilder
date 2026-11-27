import 'package:flutter/material.dart';
import 'catalog.dart';
import 'tournament_views.dart' show confirmRemoval;

class RoundView extends StatefulWidget {
  final Catalog catalog;
  final String id;
  const RoundView(this.catalog, this.id, {super.key});
  @override
  State<RoundView> createState() => _RoundViewState();
}

class _RoundViewState extends State<RoundView> {
  late final record = widget.catalog.round(widget.id);
  late final bo3 =
      widget.catalog.event(record['tournament_id'])['format'] == 'bo3';
  late final legacy = bo3 && hasLegacyThirdGame(sets);
  late bool editing = record['status'] == 'draft' && !legacy;
  late String stage = record['stage'], cut = record['top_cut_stage'] ?? 'top8';
  late String opponent = record['opponent_name'],
      champion = record['opponent_champion'],
      notes = record['notes'];
  late String? result = record['result'];
  late List<String?> sets = widget.catalog.games(widget.id);
  void beginEdit() {
    setState(() {
      editing = true;
      if (legacy) {
        sets = changeSet(sets, 1, 'draw');
        result = bo3Preview(sets);
      }
    });
  }

  void change(int index, String? value) {
    final next = changeSet(sets, index, value);
    if (sets.skip(index + 1).nonNulls.length >
        next.skip(index + 1).nonNulls.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이후 세트 기록을 지웠습니다.')));
    }
    setState(() {
      sets = next;
      result = bo3Preview(sets);
    });
    if (record['status'] == 'draft' && !legacy) save(false, close: false);
  }

  void save(bool complete, {bool close = true}) {
    widget.catalog.saveRound(
      widget.id,
      stage: stage,
      cut: cut,
      opponent: opponent,
      champion: champion,
      notes: notes,
      complete: complete,
      result: result,
      sets: bo3 ? sets : null,
    );
    if (close) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('라운드 ${record['round_number']}'),
      actions: [
        IconButton(
          tooltip: '라운드 삭제',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            if (await confirmRemoval(context, '라운드') && context.mounted) {
              widget.catalog.deleteRound(widget.id);
              Navigator.pop(context);
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (bo3) ...[
            for (var i = 0; i < 3; i++)
              ResultChoices(
                label: '${i + 1}세트',
                value: sets[i],
                onChange: editing && canRecordSet(sets, i)
                    ? (v) => change(i, v)
                    : null,
              ),
            Text(
              '${editing || record['status'] == 'draft' ? '잠정 결과' : '확정 결과'} · ${roundResultLabel(result, sets: sets)}',
            ),
          ],
          if (!bo3)
            ResultChoices(
              label: 'BO1',
              value: result,
              onChange: editing ? (v) => setState(() => result = v) : null,
            ),
          if (legacy)
            Text(
              editing
                  ? '이전 규칙의 3세트 기록을 제외했습니다. 저장하면 변경 사항을 반영합니다.'
                  : '이전 규칙으로 2세트 무승부 이후 3세트가 기록된 라운드입니다.',
            ),
          if (!editing)
            OutlinedButton(onPressed: beginEdit, child: const Text('결과 수정')),
          if (editing) ...[
            FilledButton(
              onPressed: result == null ? null : () => save(true),
              child: const Text('라운드 완료'),
            ),
            TextButton(
              onPressed: () => save(false),
              child: const Text('미완료로 저장'),
            ),
            if (record['status'] == 'completed' || legacy)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('수정 취소'),
              ),
          ],
          DropdownButtonFormField<String>(
            initialValue: stage,
            decoration: const InputDecoration(labelText: '라운드 종류'),
            items: const [
              DropdownMenuItem(value: 'swiss', child: Text('Swiss')),
              DropdownMenuItem(value: 'top_cut', child: Text('Top Cut')),
            ],
            onChanged: editing ? (v) => setState(() => stage = v!) : null,
          ),
          if (stage == 'top_cut')
            DropdownButtonFormField<String>(
              initialValue: cut,
              decoration: const InputDecoration(labelText: 'Top Cut 단계'),
              items: [
                for (final e in cutStages.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: editing ? (v) => setState(() => cut = v!) : null,
            ),
          for (final (label, value, change)
              in <(String, String, ValueChanged<String>)>[
                ('상대 이름', opponent, (v) => opponent = v),
                ('상대 챔피언', champion, (v) => champion = v),
                ('라운드 메모', notes, (v) => notes = v),
              ])
            TextFormField(
              initialValue: value,
              readOnly: !editing,
              decoration: InputDecoration(labelText: label),
              onChanged: change,
            ),
        ],
      ),
    ),
  );
}

class ResultChoices extends StatelessWidget {
  final String label;
  final String? value;
  final ValueChanged<String?>? onChange;
  const ResultChoices({
    super.key,
    required this.label,
    required this.value,
    this.onChange,
  });
  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 6,
    children: [
      Text('$label · ${matchResults[value] ?? '미기록'}'),
      for (final e in matchResults.entries)
        ChoiceChip(
          label: Text(e.value),
          selected: value == e.key,
          onSelected: onChange == null
              ? null
              : (chosen) => onChange!(chosen ? e.key : null),
        ),
    ],
  );
}
