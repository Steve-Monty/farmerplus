const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const { createHash } = require('node:crypto');

test('map credits start collapsed while retaining the native disclosure', () => {
  const classes = new Set(['maplibregl-compact-show']);
  let removedOpen = false;
  const control = { classList: { add: v => classes.add(v), remove: v => classes.delete(v) },
    removeAttribute: name => { removedOpen = name === 'open'; } };
  class AttributionControl {
    constructor(options) { this.options = options; }
    onAdd() { return control; }
  }
  const context = { window: {}, pmtiles: { Protocol: class {} }, maplibregl: { AttributionControl, addProtocol() {} } };
  vm.runInNewContext(readFileSync(join(__dirname, '../web/browser_maps.js'), 'utf8'), context);
  const instance = new context.maplibregl.AttributionControl();
  assert.equal(instance.options.compact, true);
  assert.equal(instance.onAdd({}), control);
  assert.equal(classes.has('maplibregl-compact'), true);
  assert.equal(classes.has('maplibregl-compact-show'), false);
  assert.equal(removedOpen, true);
});

test('offline PMTiles reads exact local ranges and separates equal-sized archives', async () => {
  let protocol;
  const context = {
    window: {}, Blob, Uint8Array, atob,
    pmtiles: {
      Protocol: class { constructor() { protocol = this; this.sources = new Map(); this.tile = () => {}; } get(k) { return this.sources.get(k); } add(p) { this.sources.set(p.source.getKey(), p); } },
      PMTiles: class { constructor(source) { this.source = source; } },
    },
    maplibregl: { addProtocol: (name, handler) => { assert.equal(name, 'pmtiles'); assert.equal(typeof handler, 'function'); } },
  };
  vm.runInNewContext(readFileSync(join(__dirname, '../web/browser_maps.js'), 'utf8'), context);
  const register = bytes => context.window.farmerRegisterMapArchive(createHash('sha256').update(bytes).digest('hex'), bytes.toString('base64'));
  const first = register(Buffer.from([1, 2, 3, 4]));
  const second = register(Buffer.from([4, 3, 2, 1]));
  assert.notEqual(first, second);
  const range = await protocol.get(first).source.getBytes(1, 2);
  assert.deepEqual([...new Uint8Array(range.data)], [2, 3]);
  assert.equal(register(Buffer.from([1, 2, 3, 4])), first);
  assert.equal(protocol.sources.size, 2);
  await assert.rejects(protocol.get(first).source.getBytes(-1, 2), /Invalid map byte range/);
});

test('bundled PMTiles protocol parses a local archive without any network fetch', async () => {
  let handler;
  const context = { window: {}, Blob, Uint8Array, atob, TextDecoder, TextEncoder, AbortController, console,
    fetch() { throw new Error('Offline archives must not fetch network data'); },
    maplibregl: { addProtocol(name, fn) { handler = fn; } },
  };
  vm.createContext(context);
  vm.runInContext(readFileSync(join(__dirname, '../web/vendor/pmtiles.js'), 'utf8'), context);
  vm.runInContext(readFileSync(join(__dirname, '../web/browser_maps.js'), 'utf8'), context);
  // Minimal valid PMTiles v3 archive, containing an empty uncompressed root.
  const archive = Buffer.alloc(128);
  archive.write('PMTiles'); archive[7] = 3;
  archive.writeBigUInt64LE(127n, 8); archive.writeBigUInt64LE(1n, 16);
  for (const offset of [24, 40, 56]) archive.writeBigUInt64LE(128n, offset);
  archive[96] = 1; archive[97] = 1; archive[98] = 1; archive[99] = 1;
  archive.writeInt32LE(-1800000000, 102); archive.writeInt32LE(-850000000, 106);
  archive.writeInt32LE(1800000000, 110); archive.writeInt32LE(850000000, 114);
  const hash = createHash('sha256').update(archive).digest('hex');
  const key = context.window.farmerRegisterMapArchive(hash, archive.toString('base64'));
  const result = await handler({ type: 'json', url: 'pmtiles://' + key }, new AbortController());
  assert.deepEqual(Array.from(result.data.bounds), [-180, -85, 180, 85]);
  assert.equal(result.data.minzoom, 0);
  assert.equal(result.data.tiles[0], `pmtiles://${key}/{z}/{x}/{y}`);
});
