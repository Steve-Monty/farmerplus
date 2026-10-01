"""Small, deterministic Atlas calculations shared by scoped endpoints."""
import math
from fastapi import HTTPException


def centre(feature):
    geometry = feature['geometry']
    if geometry['type'] == 'Point':
        return geometry['coordinates']
    ring = geometry['coordinates'][0][:-1]
    return [sum(p[i] for p in ring) / len(ring) for i in (0, 1)]


def distance_km(a, b):
    lon1, lat1, lon2, lat2 = map(math.radians, [*a, *b])
    h = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin((lon2-lon1)/2)**2
    return 6371.0088 * 2 * math.asin(min(1, math.sqrt(h)))


def parse_near(value):
    if not value:
        return None
    try:
        lon, lat, radius = map(float, value.split(','))
        if not all(math.isfinite(n) for n in (lon, lat, radius)) or not -180 <= lon <= 180 or not -85 <= lat <= 85 or not 1 <= radius <= 500:
            raise ValueError()
        return lon, lat, radius
    except (ValueError, AttributeError):
        raise HTTPException(422, 'Nearby search needs longitude, latitude and a radius from 1 to 500 km')


def hexagons(features, resolution):
    import h3
    cells = {}
    for f in features:
        if f['properties']['kind'] != 'farm':
            continue
        lon, lat = centre(f)
        cell = h3.latlng_to_cell(lat, lon, resolution)
        cells.setdefault(cell, []).append(f)
    result = []
    for cell, members in cells.items():
        ring = [[lon, lat] for lat, lon in h3.cell_to_boundary(cell)]
        ring.append(ring[0])
        result.append({'type':'Feature','id':cell,'geometry':{'type':'Polygon','coordinates':[ring]},
            'properties':{'name':f'{len(members)} farm centres','count':len(members),'cell':cell,
                'owners':sorted({m['properties']['owner'] for m in members}),
                'members':[m['id'] for m in members]}})
    return result
