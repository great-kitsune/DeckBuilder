import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'catalog.dart';
import 'card_image.dart';
import 'search_view.dart';

Future<String?> _deckName(
  BuildContext context,
  String title, [
  String initial = '',
]) {
  var name = initial;
  return showDialog<String>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, redraw) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          decoration: const InputDecoration(labelText: '덱 이름'),
          onChanged: (value) => redraw(() => name = value),
          onFieldSubmitted: (_) {
            if (name.trim().isNotEmpty) Navigator.pop(dialog, name.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: name.trim().isEmpty
                ? null
                : () => Navigator.pop(dialog, name.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
}

class DeckList extends StatefulWidget {
  final Catalog catalog;
  final ValueListenable<int> catalogRevision;
  final VoidCallback onCatalogChange;
  const DeckList(
    this.catalog, {
    super.key,
    required this.catalogRevision,
    required this.onCatalogChange,
  });
  @override
  State<DeckList> createState() => _DeckListState();
}

class _DeckListState extends State<DeckList> {
  Future<void> open(DeckInfo deck) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: widget.catalogRevision,
          builder: (context, revision, _) => DeckEditor(
            widget.catalog,
            deck,
            revision: revision,
            onCatalogChange: widget.onCatalogChange,
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> create() async {
    final name = await _deckName(context, '새 Standard 덱');
    if (name == null || !mounted) return;
    try {
      final id = widget.catalog.createDeck(name);
      setState(() {});
      await open((id: id, name: name));
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  Future<void> manage(String action, DeckInfo deck) async {
    final catalog = widget.catalog;
    try {
      switch (action) {
        case '이름 변경':
          final name = await _deckName(context, action, deck.name);
          if (name == null || !mounted) return;
          catalog.renameDeck(deck.id, name);
        case '복제':
          catalog.duplicateDeck(deck);
        case '삭제':
          final yes = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('덱 삭제'),
              content: Text('‘${deck.name}’ 덱을 삭제하시겠습니까?'),
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
          );
          if (yes != true || !mounted) return;
          catalog.deleteDeck(deck.id);
      }
      setState(() {});
    } catch (e) {
      if (mounted) _showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final decks = widget.catalog.decks();
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: create,
              icon: const Icon(Icons.add),
              label: const Text('새 덱'),
            ),
          ),
        ),
        Expanded(
          child: decks.isEmpty
              ? const Center(child: Text('저장된 덱이 없습니다.'))
              : ListView.builder(
                  itemCount: decks.length,
                  itemBuilder: (context, i) {
                    final deck = decks[i];
                    return ListTile(
                      leading: const Icon(Icons.style_outlined),
                      title: Text(deck.name),
                      subtitle: const Text('Standard'),
                      onTap: () => open(deck),
                      trailing: PopupMenuButton<String>(
                        tooltip: '덱 관리',
                        onSelected: (action) => manage(action, deck),
                        itemBuilder: (_) => [
                          for (final action in ['이름 변경', '복제', '삭제'])
                            PopupMenuItem(value: action, child: Text(action)),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

void _showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('덱 편집 실패 · $error')));
}

class DeckEditor extends StatefulWidget {
  final Catalog catalog;
  final DeckInfo deck;
  final int revision;
  final VoidCallback onCatalogChange;
  const DeckEditor(
    this.catalog,
    this.deck, {
    super.key,
    required this.revision,
    required this.onCatalogChange,
  });
  @override
  State<DeckEditor> createState() => _DeckEditorState();
}

class _DeckEditorState extends State<DeckEditor> {
  DeckZone zone = DeckZone.main;
  bool picking = false, openedSearch = false;

  void change(VoidCallback write) {
    try {
      write();
    } catch (e) {
      _showError(context, e);
    }
    setState(() {});
  }

  Future<void> detail(DeckEntry e) async {
    await Navigator.push(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => CardDetail(
          widget.catalog,
          e.card,
          e.edition.isEmpty ? null : e.edition,
        ),
      ),
    );
    if (!mounted) return;
    widget.onCatalogChange();
    setState(() {});
  }

  Future<void> move(DeckEntry entry, DeckZone target) async {
    int? count = 1;
    if (entry.quantity > 1) {
      var quantity = 1;
      count = await showDialog<int>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, redraw) => AlertDialog(
              title: Text('${target.label}로 이동'),
              content: TextFormField(
                autofocus: true,
                initialValue: '1',
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '이동 수량 (1–${entry.quantity})',
                ),
                onChanged: (v) => redraw(() => quantity = int.tryParse(v) ?? 0),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: quantity < 1 || quantity > entry.quantity
                      ? null
                      : () => Navigator.pop(ctx, quantity),
                  child: const Text('이동'),
                ),
              ],
            ),
          );
        },
      );
    }
    if (count != null && mounted) {
      change(() => widget.catalog.takeCopies(entry, count!, to: target));
    }
  }

  void closePicker() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => picking = false);
  }

  String amount(DeckZone zone, int quantity, int points) =>
      zone == DeckZone.sideboard ? '$points점' : '$quantity장';

  Widget entryTile(DeckEntry e, DeckCounts counts, bool grid) {
    final copies =
        counts[(e.cost, normalizedName(e.name))] ?? const ZoneCopies();
    final moves = DeckZone.values.where(
      (z) => z != e.zone && e.cost.accepts(z),
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '한 장 빼기',
          icon: const Icon(Icons.remove),
          onPressed: () => change(() => widget.catalog.takeCopies(e, 1)),
        ),
        Text(amount(e.zone, e.quantity, e.quantity * e.cost.points)),
        IconButton(
          tooltip: '한 장 더하기',
          icon: const Icon(Icons.add),
          onPressed: e.cost.accepts(e.zone) && copies.allows(e.cost, 1)
              ? () => change(() => widget.catalog.incrementEntry(e))
              : null,
        ),
        PopupMenuButton<DeckZone>(
          tooltip: '구역 이동',
          enabled: moves.isNotEmpty,
          onSelected: (z) => move(e, z),
          itemBuilder: (_) => [
            for (final z in moves)
              PopupMenuItem(value: z, child: Text('${z.label}로 이동')),
          ],
        ),
      ],
    );
    final note = [
      if (e.printing.isNotEmpty)
        e.printing
      else if (e.edition.isNotEmpty)
        e.edition,
      ?e.status,
    ].join(' · ');
    if (!grid) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(e.name),
        subtitle: note.isEmpty ? null : Text(note),
        trailing: controls,
        onTap: () => detail(e),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => detail(e),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            children: [
              Expanded(
                child: CatalogThumbnail(
                  widget.catalog,
                  e.card,
                  e.edition.isEmpty ? null : e.edition,
                  spoiler: e.spoiler,
                  revision: widget.revision,
                ),
              ),
              Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (note.isNotEmpty)
                Text(note, maxLines: 1, overflow: TextOverflow.ellipsis),
              FittedBox(fit: BoxFit.scaleDown, child: controls),
            ],
          ),
        ),
      ),
    );
  }

  Widget contents(List<DeckEntry> entries, DeckCounts counts, bool wide) {
    final grid = widget.catalog.thumbnailGrid;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth - 24) / 170).floor().clamp(
          1,
          16,
        );
        final slivers = <Widget>[];
        for (final group in DeckZone.values) {
          final cards = entries.where((e) => e.zone == group).toList();
          final total = cards.fold(0, (n, e) => n + e.quantity);
          final points = cards.fold(
            0,
            (n, e) => n + e.quantity * e.cost.points,
          );
          slivers.add(
            SliverToBoxAdapter(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${group.label} · ${amount(group, total, points)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('카드 추가'),
                          key: ValueKey('add-${group.name}'),
                          onPressed: () => setState(() {
                            zone = group;
                            openedSearch = true;
                            picking = !wide;
                          }),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ),
            ),
          );
          final delegate = SliverChildBuilderDelegate(
            (_, i) => entryTile(cards[i], counts, grid),
            childCount: cards.length,
          );
          slivers.add(
            grid
                ? SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: 235,
                    ),
                    delegate: delegate,
                  )
                : SliverList(delegate: delegate),
          );
        }
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
              sliver: SliverMainAxisGroup(slivers: slivers),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final entries = widget.catalog.deckEntries(widget.deck.id);
    final counts = countCopies(entries);
    final search = Column(
      children: [
        DropdownButton<DeckZone>(
          value: zone,
          onChanged: (v) => setState(() => zone = v!),
          items: [
            for (final z in DeckZone.values)
              DropdownMenuItem(value: z, child: Text('${z.label}에 추가')),
          ],
        ),
        Expanded(
          child: SearchView(
            widget.catalog,
            revision: widget.revision,
            deckCounts: counts,
            requiredCost: DeckCost.values
                .where((cost) => cost.primary == zone)
                .firstOrNull,
            onCatalogChange: widget.onCatalogChange,
            onPick: (card, edition) => change(
              () =>
                  widget.catalog.addToDeck(widget.deck.id, zone, card, edition),
            ),
          ),
        ),
      ],
    );
    final showPicker = !wide && picking;
    return PopScope(
      canPop: !showPicker,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showPicker) closePicker();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            showPicker ? '카드 추가 · ${widget.deck.name}' : widget.deck.name,
          ),
          leading: showPicker
              ? IconButton(
                  icon: const BackButtonIcon(),
                  tooltip: '덱으로',
                  onPressed: closePicker,
                )
              : null,
        ),
        body: SafeArea(
          top: false,
          child: wide
              ? Row(
                  children: [
                    Expanded(child: search),
                    const VerticalDivider(width: 1),
                    Expanded(child: contents(entries, counts, true)),
                  ],
                )
              : IndexedStack(
                  index: showPicker ? 1 : 0,
                  children: [
                    contents(entries, counts, false),
                    if (openedSearch) search else const SizedBox.shrink(),
                  ],
                ),
        ),
      ),
    );
  }
}
