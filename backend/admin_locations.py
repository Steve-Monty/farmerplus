"""Display-only registration fallback. Never deletes the source GPS record."""
import math
from place_colors import resolve_place_colors


def valid_location(data):
    try:
        lat, lon = float(data['lat']), float(data['lon'])
        return (not isinstance(data['lat'], bool) and not isinstance(data['lon'], bool)
                and math.isfinite(lat + lon) and -85 <= lat <= 85 and -180 <= lon <= 180)
    except (KeyError, ValueError, TypeError):
        return False


def annotate_locations(people):
    for person in people:
        records = person['records']
        colors = resolve_place_colors([r for r in records if r['kind'] == 'pin'])
        mapped = any(r['kind'] == 'farm' and r['mapping'] == 'Mapped' for r in records)
        places = [r for r in records if r['kind'] == 'pin' and r['data'].get('farmId')
                  and r['data'].get('purpose') != 'registration' and valid_location(r['data'])]
        pins = sorted((r for r in records if r['kind'] == 'pin' and r not in places and valid_location(r['data'])),
                      key=lambda r: (str(r['data'].get('capturedAt') or r['updated']), r['id']))
        registration = pins[0] if pins else None
        for r in records:
            if r['kind'] == 'pin':
                r['hideOnMap'] = False if r in places else mapped or r is not registration
                r['placeColor'] = colors[str(r['id'])]
        person['registrationLocation'] = registration['data'] if registration else None
        person['locationAvailable'] = mapped or bool(places) or registration is not None or any(
            r['kind'] == 'field' and r['mapping'] == 'Mapped' for r in records)
        person['locationStatus'] = ('Farm boundary' if mapped else 'Registration pin' if registration
                                    else 'Farm place' if places else 'Field boundary' if person['locationAvailable'] else 'Location unavailable')
