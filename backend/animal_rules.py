"""Pure animal command rules. App-owned data never enters legacy record sync."""
from copy import deepcopy
from datetime import date
import math
import re
from uuid import UUID

BREEDS = {
    'cattle': ['Angus', 'Hereford', 'Charolais', 'Holstein-Friesian', 'Jersey', 'Brown Swiss', 'Brahman', 'Simmental', 'Limousin', 'Nelore'],
    'pigs': ['Large White (Yorkshire)', 'Landrace', 'Duroc', 'Pietrain', 'Hampshire', 'Berkshire'],
    'chicken': ['Cornish Cross', 'Ross 308', 'Cobb 500', 'Leghorn', 'Rhode Island Red', 'Plymouth Rock', 'Hubbard', 'Arbor Acres', 'Lohmann Brown', 'Hy-Line Brown'],
    'goats': ['Saanen', 'Anglo-Nubian (Nubian)', 'Boer', 'Toggenburg', 'Alpine', 'West African Dwarf', 'Angora', 'Creole'],
    'sheep': ['Merino', 'Suffolk', 'Dorper', 'Awassi', 'Texel', 'Dorset', 'Rambouillet', 'East Friesian', 'Lacaune', 'Karakul'],
}
TYPES = [{'id': key, 'name': name} for key, name in zip(BREEDS, ['Cattle', 'Pigs', 'Chicken', 'Goats', 'Sheep'])]
PROFILE_FIELDS = {'name', 'tag', 'breed', 'sex', 'birthDate', 'estimatedAge', 'purpose', 'source', 'acquisitionDate', 'notes', 'photo'}
EVENT_TYPES = {'addition', 'departure', 'return', 'move', 'weight', 'care', 'observation', 'note', 'count', 'identify', 'opening'}

class RuleError(ValueError):
    pass

def check(condition, message):
    if not condition:
        raise RuleError(message)

def uid(value):
    try:
        check(isinstance(value, str) and str(UUID(value)) == value, 'Use a valid record identifier.')
    except (ValueError, TypeError, AttributeError):
        raise RuleError('Use a valid record identifier.') from None
    return value

def text(value, label='Text', limit=160, required=False):
    check(isinstance(value, str), f'{label} must be text.')
    value = value.strip()
    check(len(value) <= limit and (not required or bool(value)), f'Check {label.lower()} (maximum {limit} characters).')
    return value

def day(value, today):
    check(isinstance(value, str) and bool(re.fullmatch(r'\d{4}-\d{2}-\d{2}', value)), 'Choose a valid date.')
    try:
        check(date.fromisoformat(value).isoformat() == value and value <= today, 'Choose today or an earlier date.')
    except ValueError:
        raise RuleError('Choose a valid date.') from None
    return value

def count(value, minimum=0):
    check(type(value) is int and minimum <= value <= 10000000, 'Enter a whole number of animals within the allowed range.')
    return value

def empty_state():
    return {'profiles': [], 'events': [], 'types': [], 'breeds': []}

def profile(state, key):
    found = next((p for p in state['profiles'] if p['id'] == key and not p.get('deleted')), None)
    check(found is not None, 'This animal or group is no longer available.')
    return found

def location(farm_id, location_id, context):
    uid(farm_id)
    check(farm_id in context['farms'], 'Choose one of your saved farms.')
    if location_id:
        uid(location_id)
        check(context['locations'].get(location_id) == farm_id, 'Choose a location on this farm.')
    return location_id or None

def profile_values(values, today):
    result = {}
    for key in PROFILE_FIELDS:
        if key in values:
            result[key] = text(values[key] or '', key, 4000 if key == 'notes' else 160)
    check(result.get('sex', '') in {'', 'female', 'male', 'unknown'}, 'Choose a valid sex.')
    check(not (result.get('birthDate') and result.get('estimatedAge')), 'Enter a birth date or an estimated age, not both.')
    for key in ['birthDate', 'acquisitionDate']:
        if result.get(key): day(result[key], today)
    if result.get('photo'):
        check(bool(re.fullmatch('[a-f0-9]{64}', result['photo'])), 'Choose a valid photo.')
    return result

def new_profile(state, payload, kind, context, today):
    key = uid(payload.get('id'))
    check(not any(p['id'] == key for p in state['profiles']), 'This animal record already exists.')
    species = payload.get('species')
    check(species in BREEDS or any(t['id'] == species and not t.get('retired') for t in state['types']), 'Choose an animal type.')
    values = profile_values(payload, today)
    check(bool(values.get('name') or (kind == 'individual' and values.get('tag'))), 'Enter a name or tag.')
    loc = location(payload.get('farmId'), payload.get('locationId'), context)
    p = {'id': key, 'kind': kind, 'species': species, 'initialFarmId': payload['farmId'], 'initialLocationId': loc, **values}
    state['profiles'].append(p)
    return p

def event_values(payload, event_type, state, context, today):
    p = profile(state, payload.get('subjectId'))
    e = {'id': uid(payload['eventId']), 'type': event_type, 'subjectId': p['id'], 'occurredOn': day(payload.get('occurredOn'), today),
         'notes': text(payload.get('notes', ''), 'Notes', 4000), 'reason': text(payload.get('reason', ''), 'Reason', 160),
         'photo': text(payload.get('photo', ''), 'Photo', 64)}
    check(not e['photo'] or bool(re.fullmatch('[a-f0-9]{64}', e['photo'])), 'Choose a valid photo.')
    if event_type in {'addition', 'departure', 'return', 'move', 'count', 'opening', 'identify'}:
        e['quantity'] = count(payload.get('quantity', 1), 0 if event_type == 'count' else 1)
    if event_type in {'count', 'departure', 'addition', 'return'}:
        check(bool(e['reason']), 'Explain what happened.')
    if event_type in {'care', 'observation', 'note'}:
        check(bool(e['notes']), 'Describe what happened.')
        if payload.get('affectedCount') is not None: e['affectedCount'] = count(payload['affectedCount'], 1)
        e['quantityText'] = text(payload.get('quantityText', ''), 'Quantity and unit')
    if event_type == 'weight':
        weight = payload.get('weight')
        check(type(weight) in {int, float} and math.isfinite(weight) and 0 < weight <= 100000000, 'Enter a positive weight.')
        check(payload.get('unit') in {'kg', 'lb', 'g'}, 'Choose a weight unit.')
        check(payload.get('basis') in {'individual', 'group-total', 'group-average'}, 'Choose what this weight measures.')
        check((p['kind'] == 'individual') == (payload['basis'] == 'individual'), 'The weight basis must match this animal or group.')
        e.update(weight=weight, unit=payload['unit'], basis=payload['basis'])
    if event_type in {'opening', 'move', 'return', 'identify'}:
        farm_id = payload.get('farmId', p.get('farmId', p['initialFarmId']))
        e.update(farmId=farm_id, locationId=location(farm_id, payload.get('locationId'), context))
    if event_type in {'move', 'identify'}:
        e['destinationId'] = payload.get('destinationId') or None
        if e['destinationId']: uid(e['destinationId'])
    return e

def project(state):
    """Replay history, including backdated corrections; reject unsafe intermediate states."""
    by_id = {p['id']: p for p in state['profiles']}
    for p in by_id.values():
        p.update(count=0, farmId=p['initialFarmId'], locationId=p['initialLocationId'], active=False, lastDeparture='')
    for event in sorted(state['events'], key=lambda e: (e['occurredOn'], e['order'], e['id'])):
        if event.get('void'): continue
        p = by_id.get(event['subjectId'])
        check(p is not None and not p.get('deleted'), 'A later record still depends on this animal. Correct it first.')
        n, kind = event.get('quantity', 0), event['type']
        if kind == 'opening':
            check(p['count'] == 0, 'An opening balance already exists.')
            p.update(count=n, farmId=event['farmId'], locationId=event['locationId'])
        elif kind == 'addition':
            check(p['kind'] == 'group', 'Additions belong to a group.')
            p['count'] += n
        elif kind == 'count':
            check(p['kind'] == 'group', 'Count corrections belong to a group.')
            p['count'] = n
        elif kind == 'departure':
            check(p['count'] >= n, 'There are not enough animals on this date. Check later dependent records too.')
            p['count'] -= n
            p['lastDeparture'] = event['reason']
        elif kind == 'return':
            check(p['kind'] == 'individual' and p['count'] == 0 and p['lastDeparture'] and p['lastDeparture'].lower() != 'died', 'Correct the departure before returning this animal.')
            p.update(count=1, farmId=event['farmId'], locationId=event['locationId'], lastDeparture='')
        elif kind in {'move', 'identify'}:
            check(p['count'] >= n, 'There are not enough animals to move on this date.')
            target_id = event.get('destinationId')
            if target_id:
                target = by_id.get(target_id)
                check(target is not None and not target.get('deleted') and target_id != p['id'], 'Choose a different destination group.')
                check(p['kind'] == 'group' and target['species'] == p['species'], 'Only matching animals can be transferred together.')
                check(target.get('breed', '') == p.get('breed', ''), 'Choose a group with the same breed, or create a new group.')
                check((kind == 'identify' and target['kind'] == 'individual' and n == 1 and target['count'] == 0) or (kind == 'move' and target['kind'] == 'group'), 'Check the destination animal type.')
                check(target['count'] == 0 or (target['farmId'] == event['farmId'] and target['locationId'] == event['locationId']), 'The destination group is at another location.')
                p['count'] -= n
                target.update(count=target['count'] + n, farmId=event['farmId'], locationId=event['locationId'])
                check(target['count'] <= 10000000, 'This history would create an invalid animal count.')
            else:
                check(kind == 'move' and n == p['count'], 'A partial move needs a destination group.')
                p.update(farmId=event['farmId'], locationId=event['locationId'])
        else:
            check(p['count'] > 0, 'This animal was not present on the record date.')
            check(event.get('affectedCount', 1) <= p['count'], 'The affected number exceeds the animals present on this date.')
        check(0 <= p['count'] <= 10000000 and (p['kind'] == 'group' or p['count'] <= 1), 'This history would create an invalid animal count.')
    tags = set()
    for p in state['profiles']:
        p['active'] = p['count'] > 0 and not p.get('archived') and not p.get('deleted')
        if p.get('tag') and not p.get('deleted'):
            key = (p['farmId'], p['tag'].strip().lower())
            check(key not in tags, 'This tag is already recorded on the farm.')
            tags.add(key)
        check(not p.get('archived') or p['count'] == 0, 'An archived animal has later active records. Restore it first.')
    return state

def apply(state, command, context, today=None):
    today = today or date.today().isoformat()
    s = deepcopy(state)
    name, payload = command.get('name'), command.get('payload', {})
    check(isinstance(payload, dict), 'Invalid command details.')
    if name in {'animals.createIndividual', 'animals.createGroup'}:
        kind = 'group' if name.endswith('Group') else 'individual'
        p = new_profile(s, payload, kind, context, today)
        e = event_values({**payload, 'subjectId': p['id'], 'quantity': payload.get('quantity') if kind == 'group' else 1}, 'opening', s, context, today)
        check(not any(item['id'] == e['id'] for item in s['events']), 'This record identifier is already used.')
        s['events'].append({**e, 'order': len(s['events']), 'revisions': []})
    elif name == 'animals.updateProfile':
        p = profile(s, payload.get('id'))
        check(not ({'farmId', 'locationId', 'count', 'quantity', 'species', 'kind'} & payload.keys()), 'Use a movement or count record for this change.')
        p.update(profile_values({**p, **payload}, today))
        check(bool(p.get('name') or (p['kind'] == 'individual' and p.get('tag'))), 'Enter a name or tag.')
    elif name in {'animals.archive', 'animals.restore', 'animals.removeMistakenProfile'}:
        p = profile(s, payload.get('id'))
        if name == 'animals.restore': p['archived'] = False
        elif name == 'animals.archive':
            check(p['count'] == 0, 'Record animals leaving before archiving this record.')
            p['archived'] = True
        else:
            reason = text(payload.get('reason', ''), 'Reason', required=True)
            linked = [e for e in s['events'] if not e.get('void') and (e['subjectId'] == p['id'] or e.get('destinationId') == p['id'])]
            check(all(e['type'] == 'opening' for e in linked), 'Correct or remove later dependent records first.')
            for e in linked:
                e['revisions'].append({'before': {k:v for k,v in e.items() if k != 'revisions'}, 'reason': reason})
                e['void'] = True
            p['deleted'] = True
    elif name in {'events.correct', 'events.void'}:
        e = next((e for e in s['events'] if e['id'] == payload.get('id')), None)
        check(e is not None, 'The record no longer exists.')
        reason = text(payload.get('correctionReason', ''), 'Correction reason', required=True)
        before = {k:deepcopy(v) for k,v in e.items() if k != 'revisions'}
        if name == 'events.void': e['void'] = True
        else:
            replacement = payload.get('replacement', {})
            check(isinstance(replacement, dict), 'Check correction details.')
            check(not ({'id', 'type', 'subjectId', 'destinationId', 'farmId'} & replacement.keys()), 'A correction cannot change the animals involved. Void the record and create a new one.')
            candidate = event_values({**e, **replacement, 'eventId': e['id']}, e['type'], s, context, today)
            e.update(candidate)
            e['void'] = False
        e['revisions'].append({'before': before, 'reason': reason})
    elif name and (name.startswith('events.record') or name == 'events.correctCount' or name == 'animals.identifyFromGroup'):
        mapping = {'events.recordAddition':'addition','events.recordDeparture':'departure','events.recordReturn':'return','events.recordMove':'move','events.recordWeight':'weight','events.recordCare':'care','events.recordObservation':'observation','events.recordNote':'note','events.correctCount':'count','animals.identifyFromGroup':'identify'}
        check(name in mapping, 'Unsupported record action.')
        kind = mapping[name]
        if payload.get('newDestination'):
            src = profile(s, payload.get('subjectId'))
            dest = payload['newDestination']
            check(isinstance(dest, dict), 'Check destination details.')
            new_profile(s, {**dest, 'id': payload.get('destinationId'), 'species':src['species'], 'breed':src.get('breed',''), 'farmId':payload.get('farmId',src['farmId']), 'locationId':payload.get('locationId')}, 'individual' if kind == 'identify' else 'group', context, today)
        e = event_values(payload, kind, s, context, today)
        check(not any(item['id'] == e['id'] for item in s['events']), 'This record identifier is already used.')
        s['events'].append({**e, 'order':len(s['events']), 'revisions':[]})
    elif name and name.startswith('options.'):
        match = re.fullmatch(r'options\.(create|rename|retire)(Breed|Type)', name)
        check(match is not None, 'Unsupported animal option.')
        action, kind = match.groups()
        rows = s['breeds' if kind == 'Breed' else 'types']
        key = uid(payload.get('id'))
        row = next((r for r in rows if r['id'] == key), None)
        if action == 'create':
            check(row is None, 'This option already exists.')
            row = {'id':key}
            if kind == 'Breed':
                species = payload.get('species')
                check(species in BREEDS or any(t['id'] == species and not t.get('retired') for t in s['types']), 'Choose an animal type.')
                row['species'] = species
            rows.append(row)
        check(row is not None, 'Standard choices cannot be changed; choose a custom option.')
        if action == 'retire': row['retired'] = True
        else:
            label = text(payload.get('name'), 'Name', required=True)
            check(not any(r['id'] != key and r['name'].lower() == label.lower() and r.get('species') == row.get('species') for r in rows), 'That option already exists.')
            row['name'] = label
    else:
        raise RuleError('Unsupported animal action.')
    check(len(s['profiles']) <= 10000 and len(s['events']) <= 50000, 'This app has reached its record limit. Export and contact your administrator.')
    return project(s)
