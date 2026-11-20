import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'catalog.dart';
import 'spoiler_options.dart';

class SpoilerForm extends StatefulWidget {
  final Catalog catalog;
  const SpoilerForm(this.catalog, {super.key});
  @override
  State<SpoilerForm> createState() => _SpoilerFormState();
}

class _SpoilerFormState extends State<SpoilerForm> {
  final values = <String, String>{};
  String status = '', speed = 'NONE', cost = 'none';
  String? rarity;
  final selected = <String, Set<String>>{
    for (final group in ['Type', 'Subtype', 'Class', 'Element'])
      group: <String>{},
  };
  late final Map<String, List<String>> options;
  @override
  void initState() {
    super.initState();
    options = widget.catalog.options();
    if (widget.catalog.updated == null) {
      for (final group in initialSpoilerOptions.entries) {
        options[group.key] = {...group.value, ...options[group.key]!}.toList()
          ..sort();
      }
    }
    options['Speed'] = ['NONE', 'SLOW', 'FAST'];
  }

  Widget choices(String group) {
    final multi = selected[group];
    final current = multi?.join(', ') ?? (group == 'Speed' ? speed : rarity);
    return ExpansionTile(
      key: PageStorageKey(group),
      title: Text(group),
      subtitle: Text(current == null || current.isEmpty ? '미선택' : current),
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (final value in options[group]!)
              if (multi != null)
                FilterChip(
                  label: Text(value),
                  selected: multi.contains(value),
                  onSelected: (on) => setState(() {
                    if (on) {
                      multi.add(value);
                    } else {
                      multi.remove(value);
                    }
                  }),
                )
              else
                ChoiceChip(
                  label: Text(value),
                  selected: current == value,
                  onSelected: (on) => setState(() {
                    if (group == 'Speed') {
                      speed = on ? value : 'NONE';
                    } else {
                      rarity = on ? value : null;
                    }
                  }),
                ),
          ],
        ),
      ],
    );
  }

  Uint8List? image;
  final key = GlobalKey<FormState>();
  static const fields = [
    '카드명',
    '영문명',
    '키워드',
    '효과',
    'Type',
    'Subtype',
    'Class',
    'Element',
    '세트 코드',
    '수집 번호',
    'Speed',
    'Rarity',
    '비용',
    '레벨',
    'Life',
    'Power',
    'Durability',
  ];
  Future<void> pick() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '카드 이미지',
            extensions: ['jpg', 'jpeg', 'png', 'webp'],
            mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 16 * 1024 * 1024) {
        throw const FormatException('16 MB 이하의 이미지를 선택하세요.');
      }
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          image = bytes;
          status = file.name;
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    }
  }

  void save() {
    if (!key.currentState!.validate()) return;
    final id =
        'local-${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    String field(String k) => values[k]?.trim() ?? '';
    List<String> tags(String k) => field(k)
        .split(',')
        .map((s) => s.trim().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    final card = <String, dynamic>{
      'uuid': id,
      'name': field('카드명'),
      'english_name': field('영문명'),
      'types': selected['Type']!.toList(),
      'subtypes': selected['Subtype']!.toList(),
      'classes': selected['Class']!.toList(),
      'elements': selected['Element']!.toList(),
      'effect_raw': [
        field('키워드'),
        field('효과'),
      ].where((s) => s.isNotEmpty).join('\n'),
      'keywords': tags('키워드'),
      'speed': speed == 'NONE' ? null : speed == 'FAST',
      'cost': {'type': cost, 'value': cost == 'none' ? null : field('비용')},
      for (final (k, label) in [
        ('level', '레벨'),
        ('life', 'Life'),
        ('power', 'Power'),
        ('durability', 'Durability'),
      ])
        k: int.tryParse(field(label)),
      'editions': [
        {
          'uuid': '$id-print',
          'set': {
            'prefix': field('세트 코드').isEmpty
                ? null
                : field('세트 코드').toUpperCase(),
          },
          'collector_number': field('수집 번호').isEmpty ? null : field('수집 번호'),
          'rarity': rarity,
        },
      ],
    };
    try {
      widget.catalog.transaction(() {
        widget.catalog.insert(card, spoiler: true, photo: image);
        widget.catalog.reconcileSpoilers(only: id);
      });
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => status = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('스포일러 카드 추가')),
    body: SafeArea(
      top: false,
      minimum: EdgeInsets.only(bottom: MediaQuery.sizeOf(context).height * 0.1),
      child: Form(
        key: key,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('공개된 정보만 입력하세요. 키워드는 쉼표로 구분합니다.'),
              for (final k in fields)
                if (selected.containsKey(k) || k == 'Rarity' || k == 'Speed')
                  choices(k)
                else
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: k == '카드명' ? '카드명 (필수)' : k,
                    ),
                    onChanged: (s) => values[k] = s,
                    validator: (s) {
                      if (k == '카드명' && (s ?? '').trim().isEmpty) {
                        return '카드명을 입력하세요';
                      }
                      if (['레벨', 'Life', 'Power', 'Durability'].contains(k) &&
                          (s ?? '').isNotEmpty &&
                          int.tryParse(s!) == null) {
                        return '정수를 입력하세요';
                      }
                      return null;
                    },
                  ),
              DropdownButtonFormField(
                initialValue: cost,
                decoration: const InputDecoration(labelText: '비용 종류'),
                items: [
                  for (final v in ['none', 'memory', 'reserve'])
                    DropdownMenuItem(value: v, child: Text(v)),
                ],
                onChanged: (v) => setState(() => cost = v!),
              ),
              TextButton(onPressed: pick, child: const Text('이미지 파일 선택')),
              if (image != null)
                Image.memory(
                  image!,
                  height: 120,
                  errorBuilder: (_, _, _) => const Text('미리보기 불가'),
                ),
              Text(status),
              FilledButton(onPressed: save, child: const Text('카드 저장')),
            ],
          ),
        ),
      ),
    ),
  );
}
