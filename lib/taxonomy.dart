/// Shared product vocabulary. IDs are stable; labels may be translated later.
const productionCategories = <String, List<String>>{
  'Field crops': ['Cereals', 'Pulses', 'Oilseeds', 'Roots and tubers'],
  'Horticulture': [
    'Vegetables',
    'Fruit and nuts',
    'Herbs and spices',
    'Mushrooms',
  ],
  'Industrial and plantation crops': [
    'Sugar and fibre crops',
    'Coffee, tea and cocoa',
  ],
  'Livestock': ['Cattle, sheep and goats', 'Pigs, rabbits and other livestock'],
  'Poultry': ['Meat birds', 'Eggs and breeding'],
  'Aquaculture': ['Fish, shellfish and aquatic crops'],
  'Beekeeping': ['Bees, honey and other hive products'],
  'Forestry and nurseries': [
    'Forestry and agroforestry',
    'Nursery and ornamental plants',
  ],
  'Pasture and fodder': ['Grazing and fodder production'],
  'Other': [],
};

const productionAreaTypes = [
  'Open field',
  'Net / shade house',
  'Walk-in tunnel',
  'Low tunnel',
  'Greenhouse',
  'Orchard / vineyard block',
  'Pasture / paddock',
  'Raised-bed area',
  'Aquaculture pond',
  'Livestock enclosure',
  'Grazing area',
  'Pen',
  'Poultry house',
  'Animal shed',
  'Storage / work area',
  'Conservation area',
  'Other',
];

const protectedApps = {'store', 'farm', 'wallet', 'learning', 'inbox'};
const appOwnedKinds = <String, Set<String>>{
  'my-animals': {}, // App data uses its own atomic command API.
  'coop': {},
  'diary': {'diary'},
  'planner': {'task'},
  'calculator': {'calculation'},
  'guides': {'guideprogress'},
  'stock': {'stock', 'stockmove'},
  'harvest': {'harvest', 'sale'},
};
String? owningApp(String kind) {
  for (final entry in appOwnedKinds.entries) {
    if (entry.value.contains(kind)) return entry.key;
  }
  return null;
}

List<String> suggestedApps(String? category) => switch (category) {
  'Livestock' || 'Poultry' => ['my-animals', 'stock', 'diary', 'guides'],
  'Aquaculture' => ['stock', 'diary', 'guides'],
  'Field crops' ||
  'Horticulture' ||
  'Industrial and plantation crops' => ['planner', 'stock', 'harvest'],
  _ => ['diary', 'guides', 'planner'],
};
