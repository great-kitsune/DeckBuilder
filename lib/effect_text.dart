import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'catalog.dart';

// Locate API-marked spans in the plain text. This preserves paragraph breaks,
// expanded card names and text equivalents of the API's inline stat icons.
TextSpan effectSpan(Json card) {
  final raw = card['effect_raw'] as String? ?? '';
  final markup = card['effect_html'] as String?;

  final spans = <TextSpan>[];
  int cursor = 0, emitted = 0;
  void append(String text, bool marked) {
    final value = text.trim();
    if (value.isEmpty) return;
    final start = raw.indexOf(value, cursor);
    if (start < 0) return;
    cursor = start + value.length;
    if (marked) {
      spans.add(TextSpan(text: raw.substring(emitted, start)));
      spans.add(
        TextSpan(
          text: raw.substring(start, cursor),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      emitted = cursor;
    }
  }

  void visit(dom.Node node, bool marked) {
    if (node is dom.Element) {
      marked =
          marked ||
          node.classes.contains('effect__label') ||
          node.classes.contains('effect__bubble') ||
          node.localName == 'strong' ||
          node.localName == 'b';
    }
    if (node is dom.Text) {
      append(node.data, marked);
    } else {
      for (final child in node.nodes) {
        visit(child, marked);
      }
    }
  }

  if (markup != null && markup.isNotEmpty) {
    visit(html.parseFragment(markup), false);
  }
  if (spans.isEmpty) {
    final markdown = card['effect'] as String? ?? '';
    cursor = 0;
    var offset = 0;
    for (final match in RegExp(r'\*\*(.+?)\*\*').allMatches(markdown)) {
      append(markdown.substring(offset, match.start), false);
      append(match.group(1)!, true);
      offset = match.end;
    }
  }
  spans.add(TextSpan(text: raw.substring(emitted)));
  return TextSpan(children: spans);
}
