import 'dart:math';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'catalog.dart';

class SpoilerForm extends StatefulWidget {
  final Catalog catalog;
  const SpoilerForm(this.catalog, {super.key});
  @override
  State<SpoilerForm> createState() => _SpoilerFormState();
}

class _SpoilerFormState extends State<SpoilerForm> {
  final values = <String, String>{};
  String status = '', speed = 'NONE', cost = 'none';
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
    '희귀도',
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
      'types': tags('Type'),
      'subtypes': tags('Subtype'),
      'classes': tags('Class'),
      'elements': tags('Element'),
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
          'rarity': field('희귀도').isEmpty ? null : field('희귀도'),
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
    body: Form(
      key: key,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('공개된 정보만 입력하세요. 여러 값은 쉼표로 구분합니다.'),
          for (final k in fields)
            TextFormField(
              decoration: InputDecoration(
                labelText: k == '카드명' ? '카드명 (필수)' : k,
              ),
              onChanged: (s) => values[k] = s,
              validator: (s) {
                if (k == '카드명' && (s ?? '').trim().isEmpty) return '카드명을 입력하세요';
                if (['레벨', 'Life', 'Power', 'Durability'].contains(k) &&
                    (s ?? '').isNotEmpty &&
                    int.tryParse(s!) == null) {
                  return '정수를 입력하세요';
                }
                return null;
              },
            ),
          DropdownButtonFormField(
            initialValue: speed,
            decoration: const InputDecoration(labelText: 'Speed'),
            items: [
              for (final v in ['NONE', 'SLOW', 'FAST'])
                DropdownMenuItem(value: v, child: Text(v)),
            ],
            onChanged: (v) => setState(() => speed = v!),
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
  );
}
