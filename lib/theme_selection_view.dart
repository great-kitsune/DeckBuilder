import 'package:flutter/material.dart';
import 'card_image.dart';
import 'catalog.dart';
import 'theme_repository.dart';

class ThemeSelectionView extends StatefulWidget {
  final Catalog catalog;
  final ValueNotifier<SelectedGraphic?> selected;
  final Future<SelectedGraphic> Function(Catalog, GraphicTheme) select;
  const ThemeSelectionView(
    this.catalog,
    this.selected, {
    super.key,
    this.select = selectGraphicTheme,
  });
  @override
  State<ThemeSelectionView> createState() => _ThemeSelectionViewState();
}

class _ThemeSelectionViewState extends State<ThemeSelectionView> {
  late List<GraphicTheme> candidates = graphicThemes(widget.catalog);
  String search = '';
  bool busy = false;
  Future<void> choose(GraphicTheme? item) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (item == null) {
        resetGraphicTheme(widget.catalog);
        widget.selected.value = null;
      } else {
        widget.selected.value = await widget.select(widget.catalog, item);
      }
    } catch (e) {
      if (mounted) {
        candidates = graphicThemes(widget.catalog);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('테마 선택 실패 · $e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = candidates
        .where((g) => normalizedName(g.name).contains(normalizedName(search)))
        .toList();
    final selected = widget.selected.value;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('테마 선택')),
        body: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: const Text('기본 테마'),
                trailing: selected == null ? const Icon(Icons.check) : null,
                onTap: busy ? null : () => choose(null),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: '카드명 검색',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => search = v),
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (selected != null &&
                  !candidates.any(
                    (c) =>
                        c.edition == selected.edition &&
                        c.path == selected.path,
                  ))
                ListTile(
                  title: const Text('사용 중인 저장된 테마'),
                  subtitle: Text(selected.edition),
                  trailing: const Icon(Icons.check),
                ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          widget.catalog.updated == null && candidates.isEmpty
                              ? '홈에서 카드 DB를 설치하세요.'
                              : '선택할 테마가 없습니다.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final item = items[i];
                          return ListTile(
                            key: ValueKey((item.edition, item.path)),
                            leading: SizedBox(
                              width: 44,
                              height: 64,
                              child: EditionImage(
                                item.path,
                                item.version,
                                thumbnail: true,
                              ),
                            ),
                            title: Text(item.name),
                            subtitle: Text(item.printing),
                            trailing:
                                selected?.edition == item.edition &&
                                    selected?.path == item.path
                                ? const Icon(Icons.check)
                                : null,
                            onTap: busy ? null : () => choose(item),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
