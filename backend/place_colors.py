"""Stable fallback colours for older places; saved colours travel with sync."""
import re

PALETTE = ['#d4501f', '#007f78', '#7b43a1', '#c02c64', '#216bb2', '#6f791d',
           '#a15c08', '#3e58ad', '#357a38', '#a43b32', '#087b9b', '#795548']


def resolve_place_colors(rows):
    result = {}
    used = set()
    ordered = sorted(rows, key=lambda r: str(r['id']))
    for row in ordered:
        color = row['data'].get('color')
        if isinstance(color, str) and re.fullmatch(r'#[0-9a-fA-F]{6}', color):
            result[str(row['id'])] = color.lower()
            used.add(color.lower())
    for row in ordered:
        identifier = str(row['id'])
        if identifier in result:
            continue
        hashed = 0
        for char in identifier:
            hashed = (hashed * 31 + ord(char)) & 0x7fffffff
        color = next((PALETTE[(hashed + i) % len(PALETTE)] for i in range(len(PALETTE))
                      if PALETTE[(hashed + i) % len(PALETTE)] not in used), None)
        i = 0
        while color is None or color in used:
            color = f'#{((hashed + i * 7919) & 0x7f7f7f) | 0x303030:06x}'
            i += 1
        result[identifier] = color
        used.add(color)
    return result
