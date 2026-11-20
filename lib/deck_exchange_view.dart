import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'catalog.dart';
import 'deck_png.dart';
import 'omnidex.dart';

enum _DeckAction { png, copy, validate }

class DeckExportMenu extends StatefulWidget {
  final Catalog catalog;
  final DeckInfo deck;
  const DeckExportMenu(this.catalog, this.deck, {super.key});
  @override
  State<DeckExportMenu> createState() => _DeckExportMenuState();
}

class _DeckExportMenuState extends State<DeckExportMenu> {
  bool busy = false;

  Future<void> act(_DeckAction action) async {
    setState(() => busy = true);
    try {
      final entries = widget.catalog.deckEntries(widget.deck.id);
      if (action == _DeckAction.png) {
        if (await saveDeckPng(widget.deck.name, entries) && mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('PNG를 저장했습니다.')));
        }
        return;
      }
      final raw = omnidexText(entries);
      if (action == _DeckAction.copy) {
        await Clipboard.setData(ClipboardData(text: raw));
        if (!mounted) return;
        final open = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            content: const Text('복사했습니다. Omnidex에 접속하시겠습니까?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('아니오'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('네'),
              ),
            ],
          ),
        );
        if (open == true &&
            !await launchUrl(
              Uri.https('omni.gatcg.com', '/'),
              mode: LaunchMode.externalApplication,
            )) {
          throw const FormatException(
            'Omnidex를 열 수 없습니다. omni.gatcg.com에 접속하세요.',
          );
        }
        return;
      }
      final client = http.Client();
      try {
        final catalog = widget.catalog;
        final deckId = widget.deck.id;
        final result = validateOmnidex(raw, client).then((answer) {
          if (!mounted) return answer;
          final current = catalog.deckEntries(deckId);
          if (current.isEmpty ||
              current.any((e) => e.spoiler) ||
              omnidexText(current) != raw) {
            return (
              status: ValidationStatus.unknown,
              detail: '검증 중 덱이 변경되었습니다. 다시 검증하세요.',
            );
          }
          return answer;
        });
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Omnidex 공식 검증'),
            content: FutureBuilder<ValidationResult>(
              future: result,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('미확인 · 덱을 다시 열어 검증하세요.');
                }
                final answer = snapshot.data;
                if (answer == null) {
                  return const Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 16),
                      Text('검증 중…'),
                    ],
                  );
                }
                final label = switch (answer.status) {
                  ValidationStatus.valid => '유효',
                  ValidationStatus.invalid => '무효',
                  ValidationStatus.unknown => '미확인',
                };
                return SingleChildScrollView(
                  child: SelectableText('$label\n\n${answer.detail}'),
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기'),
              ),
            ],
          ),
        );
      } finally {
        client.close();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e is FormatException ? e.message : '덱 출력 실패 · $e'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopupMenuButton<_DeckAction>(
    tooltip: '덱 출력 및 검증',
    enabled: !busy,
    onSelected: act,
    itemBuilder: (_) => const [
      PopupMenuItem(value: _DeckAction.png, child: Text('덱 리스트 PNG 저장')),
      PopupMenuItem(value: _DeckAction.copy, child: Text('Omnidex 형식 복사')),
      PopupMenuItem(value: _DeckAction.validate, child: Text('Omnidex 공식 검증')),
    ],
  );
}

class ImportDeckView extends StatefulWidget {
  final Catalog catalog;
  const ImportDeckView(this.catalog, {super.key});
  @override
  State<ImportDeckView> createState() => _ImportDeckViewState();
}

class _ImportDeckViewState extends State<ImportDeckView> {
  final name = TextEditingController();
  final recipe = TextEditingController();
  String? error;
  bool busy = false;

  @override
  void dispose() {
    name.dispose();
    recipe.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : '불러오기 실패 · $e',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> fromFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '덱 레시피',
          extensions: ['txt'],
          mimeTypes: ['text/plain'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > recipeSizeLimit) {
      throw const FormatException('레시피는 256 KB까지 지원합니다.');
    }
    final text = utf8.decode(await file.readAsBytes());
    if (!mounted) return;
    recipe.text = text;
    if (name.text.trim().isEmpty) {
      name.text = file.name.replaceFirst(
        RegExp(r'\.txt$', caseSensitive: false),
        '',
      );
    }
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty) throw const FormatException('덱 이름을 입력하세요.');
    final lines = parseDeckRecipe(recipe.text);
    final candidates = widget.catalog.recipeCandidates(lines);
    final choices = <(String, DeckZone), String>{};
    for (final line in lines) {
      final key = normalizedName(line.name);
      final ids =
          candidates[key]?.where((c) => c.cost.accepts(line.zone)).toList() ??
          [];
      if (ids.length < 2 || choices.containsKey((key, line.zone))) continue;
      final id = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('${line.name} · 동명 카드 선택'),
          children: [
            for (final c in ids)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c.id),
                child: Text(
                  [
                    c.name,
                    if (c.printing.isNotEmpty) c.printing,
                    c.id,
                  ].join(' · '),
                ),
              ),
          ],
        ),
      );
      if (id == null || !mounted) return;
      choices[(key, line.zone)] = id;
    }
    final deck = widget.catalog.importRecipe(
      name.text,
      lines,
      choices: choices,
    );
    Navigator.pop(context, deck);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('덱 레시피 불러오기')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: name,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '새 덱 이름'),
          ),
          Wrap(
            spacing: 12,
            children: [
              TextButton.icon(
                onPressed: busy ? null : () => run(fromFile),
                icon: const Icon(Icons.folder_open),
                label: const Text('TXT 열기'),
              ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        if (data?.text?.isNotEmpty != true) {
                          throw const FormatException('클립보드에 텍스트가 없습니다.');
                        }
                        if (mounted) recipe.text = data!.text!;
                      }),
                icon: const Icon(Icons.paste),
                label: const Text('붙여넣기'),
              ),
            ],
          ),
          TextField(
            controller: recipe,
            enabled: !busy,
            minLines: 9,
            maxLines: 18,
            decoration: const InputDecoration(
              labelText: 'Omnidex 레시피',
              alignLabelWithHint: true,
              hintText:
                  '# Material Deck\n1 Spirit of Fire\n\n# Main Deck\n4 Ignite the Soul\n\n# Sideboard',
              border: OutlineInputBorder(),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : () => run(save),
            child: const Text('새 덱으로 저장'),
          ),
        ],
      ),
    ),
  );
}
