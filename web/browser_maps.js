// Keep source credits available behind MapLibre's accessible information control.
if (globalThis.maplibregl?.AttributionControl) {
  const AttributionControl = globalThis.maplibregl.AttributionControl;
  globalThis.maplibregl.AttributionControl = class extends AttributionControl {
    constructor(options = {}) { super({...options, compact: true}); }
    onAdd(map) {
      const control = super.onAdd(map);
      control.classList.add('maplibregl-compact');
      control.classList.remove('maplibregl-compact-show');
      control.removeAttribute('open');
      return control;
    }
  };
}
'use strict';
(() => {
  const protocol = new pmtiles.Protocol();
  maplibregl.addProtocol('pmtiles', protocol.tile);
  window.farmerRegisterMapArchive = (contentHash, encoded) => {
    if (!/^[a-f0-9]{64}$/.test(contentHash)) throw new Error('Invalid map content identifier.');
    const key = 'blob:farmerplus-' + contentHash;
    if (protocol.get(key)) return key;
    const bytes = Uint8Array.from(atob(encoded), character => character.charCodeAt(0));
    const blob = new Blob([bytes], { type: 'application/vnd.pmtiles' });
    const source = {
      getKey: () => key,
      getBytes: async (offset, length) => {
        if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0) {
          throw new Error('Invalid map byte range.');
        }
        return { data: await blob.slice(offset, offset + length).arrayBuffer() };
      },
    };
    protocol.add(new pmtiles.PMTiles(source));
    return key;
  };
})();
