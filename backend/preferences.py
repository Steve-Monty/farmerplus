"""Allowlisted account preferences; never accept credentials or device caches."""
from fastapi import HTTPException

BOOLEAN_KEYS = {'weatherEnabled', 'weatherHere', 'reminders', 'homeHighContrast', 'animateIcons'}
ENUM_KEYS = {
    'syncMode': {'automatic', 'manual', 'wifi'},
    'mappingLanguage': {'en', 'af', 'zu'},
    'themeMode': {'system', 'light', 'dark'},
}
STRING_KEYS = {'selectedFarm', 'areaUnit', 'wallpaperPreset'}

def validate_preference(data):
    if set(data) != {'key', 'value'}:
        raise HTTPException(422, 'Preference requires key and value only')
    key, value = data['key'], data['value']
    valid = isinstance(key, str)
    if not valid:
        raise HTTPException(422, 'Invalid preference key')
    if key in BOOLEAN_KEYS:
        valid = type(value) is bool
    elif key in ENUM_KEYS:
        valid = isinstance(value, str) and value in ENUM_KEYS[key]
    elif key in STRING_KEYS:
        valid = value is None or isinstance(value, str) and len(value) <= 100
    elif key == 'glassOpacity':
        valid = type(value) in (float, int) and 0 <= value <= 1
    elif key in {'launcherOrder', 'appOrder'}:
        valid = isinstance(value, list) and len(value) <= 32 and all(isinstance(v, str) and len(v) <= 32 for v in value)
    else:
        valid = False
    if not valid:
        raise HTTPException(422, 'Invalid or device-local preference')
