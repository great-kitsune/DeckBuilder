part of 'catalog.dart';

typedef DeckSortKey = ({
  int element,
  int exalted,
  int costGroup,
  num value,
  int type,
});
const _typeOrder = [
  'CHAMPION',
  'ACTION',
  'ATTACK',
  'ALLY',
  'PHANTASIA',
  'DOMAIN',
  'REGALIA',
  'WEAPON',
  'ITEM',
];

DeckSortKey deckSortKey(Object? elements, Object? cost, Object? types) {
  Set<String> codes(Object? raw) {
    if (raw is! String || !raw.startsWith('[')) return {};
    final values = jsonDecode(raw);
    return values is List
        ? values.whereType<String>().map((s) => s.toUpperCase()).toSet()
        : {};
  }

  final el = codes(elements);
  final typeCodes = codes(types);
  final type = _typeOrder.indexWhere(typeCodes.contains);
  final text = cost?.toString().trim().toUpperCase();
  final numeric = num.tryParse(text ?? '');
  final number = numeric != null && numeric.isFinite;
  return (
    element: el.contains('NORM')
        ? 0
        : el.any(const {'FIRE', 'WATER', 'WIND'}.contains)
        ? 1
        : 2,
    exalted: el.contains('EXALTED') ? 1 : 0,
    costGroup: number
        ? 0
        : text == 'X'
        ? 1
        : 2,
    value: number ? numeric : 0,
    type: type < 0 ? _typeOrder.length : type,
  );
}

int compareDeckEntries(DeckEntry a, DeckEntry b) {
  final x = a.sortKey, y = b.sortKey;
  for (final order in [
    a.zone.index.compareTo(b.zone.index),
    x.element.compareTo(y.element),
    x.exalted.compareTo(y.exalted),
    x.costGroup.compareTo(y.costGroup),
    x.value.compareTo(y.value),
    x.type.compareTo(y.type),
    normalizedName(a.name).compareTo(normalizedName(b.name)),
    a.card.compareTo(b.card),
    a.edition.compareTo(b.edition),
  ]) {
    if (order != 0) return order;
  }
  return 0;
}
