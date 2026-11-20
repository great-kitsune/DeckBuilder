import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import 'catalog.dart';
import 'card_image.dart';
import 'effect_text.dart';

class SearchView extends StatefulWidget {
  final Catalog catalog;
  final int revision;
  final VoidCallback? onAdd, onCatalogChange;
  final void Function(String card, String? edition)? onPick;
  final Map<String, int> deckCounts;

  const SearchView(
    this.catalog, {
    required this.revision,
    this.onAdd,
    this.onCatalogChange,
    this.onPick,
    this.deckCounts = const {},
    super.key,
  });
  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  Filters filters = Filters();
  final query = TextEditingController();
  late List<sql.Row> rows;
  late Map<String, List<String>> options;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  void refresh() {
    options = widget.catalog.options();
    rows = widget.catalog.search(filters);
  }

  void search() => setState(() => rows = widget.catalog.search(filters));
  @override
  void didUpdateWidget(SearchView old) {
    super.didUpdateWidget(old);
    if (widget.revision != old.revision) refresh();
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  Widget filterPanel(void Function(VoidCallback) redraw) {
    void change(VoidCallback mutate) {
      mutate();
      search();
      redraw(() {});
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            const Expanded(child: Text('검색 필터')),
            TextButton(
              onPressed: () => change(() {
                filters = Filters();
                query.clear();
              }),
              child: const Text('초기화'),
            ),
          ],
        ),
        for (final group in facets)
          ExpansionTile(
            title: Text(group),
            subtitle: Text(
              '${filters.all.contains(group) ? 'AND' : 'OR'} · ${filters.selected[group]?.length ?? 0}개 선택',
            ),
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('OR')),
                  ButtonSegment(value: true, label: Text('AND')),
                ],
                selected: {filters.all.contains(group)},
                onSelectionChanged: (v) => change(() {
                  if (v.single) {
                    filters.all.add(group);
                  } else {
                    filters.all.remove(group);
                  }
                }),
              ),
              Wrap(
                spacing: 4,
                children: [
                  for (final v in options[group]!)
                    FilterChip(
                      label: Text(v),
                      selected: filters.selected[group]?.contains(v) ?? false,
                      onSelected: (on) => change(() {
                        final set = filters.selected.putIfAbsent(
                          group,
                          () => {},
                        );
                        if (on) {
                          set.add(v);
                        } else {
                          set.remove(v);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ),
        DropdownButtonFormField(
          key: ObjectKey(filters),
          initialValue: filters.costType,
          decoration: const InputDecoration(labelText: '비용 종류'),
          items: [
            for (final v in ['', 'memory', 'reserve', 'none'])
              DropdownMenuItem(value: v, child: Text(v.isEmpty ? '전체' : v)),
          ],
          onChanged: (v) => change(() => filters.costType = v!),
        ),
        for (final (label, value, assign)
            in <(String, int?, void Function(int?))>[
              ('최소 비용', filters.minCost, (v) => filters.minCost = v),
              ('최대 비용', filters.maxCost, (v) => filters.maxCost = v),
              ('최소 레벨', filters.minLevel, (v) => filters.minLevel = v),
              ('최대 레벨', filters.maxLevel, (v) => filters.maxLevel = v),
            ])
          TextFormField(
            key: ValueKey((filters, label)),
            initialValue: value?.toString(),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: label),
            onChanged: (s) => change(() => assign(int.tryParse(s))),
          ),
        DropdownButtonFormField(
          key: ValueKey((filters, 'legality')),
          initialValue: filters.legality,
          decoration: const InputDecoration(labelText: 'Standard 사용 제한'),
          items: [
            for (final v in ['', '제한 없음', '제한'])
              DropdownMenuItem(value: v, child: Text(v.isEmpty ? '전체' : v)),
          ],
          onChanged: (v) => change(() => filters.legality = v!),
        ),
        SwitchListTile(
          title: const Text('에디션별 보기'),
          value: filters.editions,
          onChanged: (v) => change(() => filters.editions = v),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (ctx, size) {
      final wide = size.maxWidth >= 720;
      return Row(
        children: [
          if (wide) SizedBox(width: 250, child: filterPanel((_) {})),
          Expanded(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: query,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: '카드명 · 효과 · 키워드',
                    ),
                    onChanged: (s) {
                      filters.text = s;
                      search();
                    },
                  ),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  children: [
                    Text('${rows.length}건'),
                    if (!wide)
                      TextButton.icon(
                        icon: const Icon(Icons.tune),
                        label: const Text('필터'),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => FractionallySizedBox(
                            heightFactor: .85,
                            child: SafeArea(
                              child: StatefulBuilder(
                                builder: (_, setModal) => filterPanel(setModal),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (widget.onAdd != null)
                      TextButton.icon(
                        onPressed: widget.onAdd,
                        icon: const Icon(Icons.add),
                        label: const Text('스포일러 추가'),
                      ),
                  ],
                ),
                Expanded(
                  child: rows.isEmpty
                      ? const Center(child: Text('검색 결과가 없습니다.'))
                      : widget.catalog.thumbnailGrid
                      ? GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate:
                              SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 170,
                                mainAxisExtent: widget.onPick == null
                                    ? 210
                                    : 260,
                                crossAxisSpacing: 8,
                                mainAxisSpacing: 8,
                              ),
                          itemCount: rows.length,
                          itemBuilder: (_, i) => resultTile(rows[i], true),
                        )
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) => resultTile(rows[i], false),
                        ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  Widget resultTile(sql.Row r, bool grid) {
    final id = r['id'] as String;
    final edition = r['edition'] as String?;
    final name = r['name'] as String;
    final spoiler = r['spoiler'] == 1;
    final subtitle = edition == null
        ? ''
        : [
            r['set_code'],
            if (r['number'] != null) '#${r['number']}',
            r['rarity'],
          ].nonNulls.join(' · ');
    Future<void> open() async {
      final changed = await Navigator.push<bool>(
        context,
        MaterialPageRoute<bool>(
          builder: (_) => CardDetail(widget.catalog, id, edition),
        ),
      );
      if (!mounted) return;
      if (changed == true) widget.onCatalogChange?.call();
      setState(refresh);
    }

    final pick = widget.onPick;
    final add = pick == null
        ? null
        : IconButton(
            tooltip: '$name 한 장 추가',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => pick(id, edition),
          );
    final count = widget.deckCounts[id] ?? 0;
    if (!grid) {
      return ListTile(
        title: Text(name),
        subtitle: pick == null
            ? (subtitle.isEmpty ? null : Text(subtitle))
            : Text(
                [
                  if (subtitle.isNotEmpty) subtitle,
                  if (spoiler) '스포일러',
                  '덱에 $count장',
                ].join(' · '),
              ),
        trailing: add ?? (spoiler ? const Chip(label: Text('스포일러')) : null),
        onTap: open,
      );
    }
    final catalog = widget.catalog;
    final local = spoiler
        ? (catalog.db.select('SELECT photo FROM spoiler_cards WHERE id=?', [
                id,
              ]).firstOrNull?['photo']
              as Uint8List?)
        : null;
    final print = catalog.db
        .select(
          """SELECT json_extract(payload,'\$.image') image,
      json_extract(payload,'\$.last_update') version FROM library_editions WHERE card=? AND (? IS NULL OR id=?) ORDER BY position LIMIT 1""",
          [id, edition, edition],
        )
        .firstOrNull;
    final path = print?['image'] as String?;
    const fallback = Icon(Icons.image_outlined);
    final image = local != null
        ? Image.memory(
            local,
            cacheWidth: 260,
            errorBuilder: (_, _, _) => fallback,
          )
        : path != null && path.startsWith('/cards/images/')
        ? EditionImage(
            path,
            print?['version']?.toString() ?? '',
            thumbnail: true,
            key: ValueKey((path, print?['version'], widget.revision)),
          )
        : fallback;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Expanded(child: Center(child: image)),
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (subtitle.isNotEmpty)
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (spoiler) const Text('스포일러'),
              if (add != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: Text('덱에 $count장')),
                    add,
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CardDetail extends StatelessWidget {
  final Catalog catalog;
  final String id;
  final String? edition;
  const CardDetail(this.catalog, this.id, this.edition, {super.key});
  Future<void> confirmDelete(BuildContext context, String name) async {
    final usage = catalog.spoilerUsage(id);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('스포일러 카드 삭제'),
        content: Text(
          [
            '‘$name’ 카드와 등록한 사진을 삭제하시겠습니까?',
            if (usage.decks > 0)
              '이 카드를 사용 중인 덱 ${usage.decks}개에서 총 ${usage.copies}장도 제거됩니다.',
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      catalog.deleteSpoiler(id, confirmedUsage: usage);
      Navigator.pop(context, true);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('카드 삭제 실패 · $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = catalog.db.select(
      'SELECT * FROM library_cards WHERE id=COALESCE((SELECT official_id FROM replacements WHERE local_id=?),?)',
      [id, id],
    ).firstOrNull;
    if (row == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('삭제된 카드입니다.')),
      );
    }
    final c = jsonDecode(row['payload'] as String) as Json;
    final photo = row['photo'] as Uint8List?;
    final prints = catalog.db.select(
      'SELECT * FROM library_editions WHERE card=? ORDER BY position,id',
      [row['id']],
    );
    final candidates = row['spoiler'] == 1
        ? catalog.candidates(id)
        : <String>[];
    Widget editionPanel(sql.Row r, bool first) {
      final e = jsonDecode(r['payload'] as String) as Json;
      final path = e['image'] as String?;
      return ExpansionTile(
        title: Text(
          "${e['set']?['name'] ?? r['set_code'] ?? '인쇄판'} #${r['number'] ?? '—'}",
        ),
        key: ValueKey(r['id']),
        initiallyExpanded: first || edition == r['id'],
        children: [
          Text('희귀도 · ${r['rarity'] ?? '—'}'),
          if (e['effect_raw'] != null) SelectableText.rich(effectSpan(e)),
          if (path != null && path.startsWith('/cards/images/'))
            EditionImage(
              path,
              e['last_update']?.toString() ?? '',
              key: ValueKey((path, e['last_update'])),
            ),
        ],
      );
    }

    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return Scaffold(
      appBar: AppBar(title: Text(c['name'] as String)),
      body: SafeArea(
        top: false,
        minimum: EdgeInsets.only(
          bottom: mobile ? MediaQuery.sizeOf(context).height * 0.1 : 0,
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (prints.isNotEmpty) editionPanel(prints.first, true),
            if (row['spoiler'] == 1) const Text('스포일러 · 공식 등록 전'),
            if (c['english_name']?.isNotEmpty == true)
              Text(c['english_name'] as String),
            if (photo != null)
              Image.memory(
                photo,
                height: 260,
                errorBuilder: (_, _, _) => const Text('이미지를 열 수 없습니다.'),
              ),
            for (final (label, k) in [
              ('Type', 'types'),
              ('Subtype', 'subtypes'),
              ('Class', 'classes'),
              ('Element', 'elements'),
            ])
              Text('$label · ${(c[k] as List? ?? []).join(', ')}'),
            Text(
              '비용 · ${c['cost']?['type'] ?? '—'} ${c['cost']?['value'] ?? ''}',
            ),
            for (final k in ['level', 'life', 'power', 'durability'])
              if (c[k] != null) Text('$k · ${c[k]}'),
            const Divider(),
            SelectableText.rich(effectSpan(c)),
            for (final rule in c['rule'] as List? ?? [])
              Text('${rule['title'] ?? ''} ${rule['description'] ?? ''}'),
            for (final r in prints.skip(1)) editionPanel(r, false),
            for (final candidate in candidates)
              TextButton(
                onPressed: () {
                  catalog.transaction(() => catalog.resolve(id, candidate));
                  Navigator.pop(context, true);
                },
                child: Text(
                  "공식 카드로 교체 · ${catalog.db.select("SELECT group_concat(set_code || ' #' || number, ', ') prints FROM editions WHERE card=?", [candidate]).single['prints'] ?? candidate} ($candidate)",
                ),
              ),
            if (row['spoiler'] == 1 && row['active'] != 0)
              OutlinedButton.icon(
                onPressed: () => confirmDelete(context, c['name'] as String),
                icon: const Icon(Icons.delete_outline),
                label: const Text('카드 삭제'),
              ),
          ],
        ),
      ),
    );
  }
}
