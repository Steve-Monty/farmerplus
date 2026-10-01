// Shared by place lists and maps. Persist the selected colour on save so
// another device and the backend display the same place the same way.
const placePalette = <String>[
  '#d4501f',
  '#007f78',
  '#7b43a1',
  '#c02c64',
  '#216bb2',
  '#6f791d',
  '#a15c08',
  '#3e58ad',
  '#357a38',
  '#a43b32',
  '#087b9b',
  '#795548',
];

bool validPlaceColor(dynamic value) =>
    value is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value);

int placeColorHash(String id) =>
    id.codeUnits.fold(0, (value, unit) => ((value * 31) + unit) & 0x7fffffff);

String unusedPlaceColor(String id, Set<String> used) {
  final hash = placeColorHash(id);
  for (var i = 0; i < placePalette.length; i++) {
    final candidate = placePalette[(hash + i) % placePalette.length];
    if (!used.contains(candidate)) return candidate;
  }
  for (var i = 0; ; i++) {
    final rgb = ((hash + i * 7919) & 0x7f7f7f) | 0x303030;
    final candidate = '#${rgb.toRadixString(16).padLeft(6, '0')}';
    if (!used.contains(candidate)) return candidate;
  }
}

Map<String, String> resolvePlaceColors(List<Map<String, dynamic>> rows) {
  final result = <String, String>{};
  final used = <String>{};
  final ordered = [...rows]
    ..sort((a, b) => a['id'].toString().compareTo(b['id'].toString()));
  for (final r in ordered) {
    if (validPlaceColor(r['data']['color'])) {
      final color = (r['data']['color'] as String).toLowerCase();
      result[r['id'].toString()] = color;
      used.add(color);
    }
  }
  for (final r in ordered) {
    final id = r['id'].toString();
    if (result.containsKey(id)) continue;
    final color = unusedPlaceColor(id, used);
    result[id] = color;
    used.add(color);
  }
  return result;
}
