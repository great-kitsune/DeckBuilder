import 'package:flutter/material.dart';
import 'catalog.dart';
import 'round_life.dart';

class LifeView extends StatefulWidget {
  final Catalog catalog;
  final String round;
  const LifeView(this.catalog, this.round, {super.key});
  @override
  State<LifeView> createState() => _LifeViewState();
}

class _LifeViewState extends State<LifeView> {
  int game = 1;
  String initialOne = '20', initialTwo = '20';
  late final bo3 =
      widget.catalog.event(
        widget.catalog.round(widget.round)['tournament_id'],
      )['format'] ==
      'bo3';
  Future<int?> input(String title, int current, {bool positive = false}) async {
    var value = current.toString();
    return showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) {
          final number = int.tryParse(value);
          return AlertDialog(
            title: Text(title),
            content: TextFormField(
              initialValue: value,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              onChanged: (v) => refresh(() => value = v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: number == null || (positive && number < 1)
                    ? null
                    : () => Navigator.pop(ctx, number),
                child: const Text('적용'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.catalog, id = widget.round, state = c.life(id, game);
    return Scaffold(
      appBar: AppBar(title: const Text('Life · 턴 관리')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (bo3)
              SegmentedButton<int>(
                segments: [
                  for (var i = 1; i <= 3; i++)
                    ButtonSegment(value: i, label: Text('$i세트')),
                ],
                selected: {game},
                onSelectionChanged: (v) => setState(() => game = v.single),
              ),
            if (state == null) ...[
              for (final number in [1, 2])
                TextFormField(
                  key: ValueKey((game, number)),
                  initialValue: number == 1 ? initialOne : initialTwo,
                  decoration: InputDecoration(
                    labelText: '플레이어 $number 초기 Life',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    signed: true,
                  ),
                  onChanged: (v) => setState(() {
                    if (number == 1) {
                      initialOne = v;
                    } else {
                      initialTwo = v;
                    }
                  }),
                ),
              FilledButton(
                onPressed:
                    int.tryParse(initialOne) == null ||
                        int.tryParse(initialTwo) == null
                    ? null
                    : () => setState(
                        () => c.startLife(
                          id,
                          game,
                          int.parse(initialOne),
                          int.parse(initialTwo),
                        ),
                      ),
                child: const Text('Life 시작'),
              ),
            ] else ...[
              for (final player in [1, 2])
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '플레이어 $player · Life ${state['life$player']}',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Wrap(
                          spacing: 4,
                          children: [
                            for (final delta in [-5, -1, 1, 5])
                              OutlinedButton(
                                onPressed: () => setState(
                                  () => c.adjustLife(id, game, player, delta),
                                ),
                                child: Text(delta > 0 ? '+$delta' : '$delta'),
                              ),
                            TextButton(
                              onPressed: () async {
                                final value = await input(
                                  '플레이어 $player Life',
                                  state['life$player'],
                                );
                                if (value != null && mounted) {
                                  setState(
                                    () => c.adjustLife(
                                      id,
                                      game,
                                      player,
                                      value,
                                      absolute: true,
                                    ),
                                  );
                                }
                              },
                              child: const Text('직접 입력'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              TextButton.icon(
                icon: const Icon(Icons.undo),
                onPressed: state['previous_life1'] == null
                    ? null
                    : () => setState(() => c.undoLife(id, game)),
                label: const Text('최근 Life 조작 취소'),
              ),
              Text(
                '턴 ${state['turn']} · 플레이어 ${state['player']}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Wrap(
                spacing: 6,
                children: [
                  FilledButton(
                    onPressed: () => setState(() => c.nextTurn(id, game)),
                    child: const Text('다음 턴'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(() => c.switchPlayer(id, game)),
                    child: const Text('플레이어 변경'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final value = await input(
                        '턴 번호',
                        state['turn'],
                        positive: true,
                      );
                      if (value != null && mounted) {
                        setState(() => c.setTurn(id, game, value));
                      }
                    },
                    child: const Text('턴 번호 수정'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
