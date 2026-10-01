const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

function worker() {
  const handlers = {}, calls = [];
  const cached = new Response('cached application');
  const context = {
    URL, Promise,
    self: { location: { origin: 'https://local.test' }, addEventListener: (name, fn) => handlers[name] = fn, skipWaiting() {}, clients: { claim() {} } },
    caches: { match: async key => { calls.push(key); return cached; } },
    fetch: async () => { throw new Error('Offline'); },
  };
  const source = readFileSync(join(__dirname, '../web/farmerplus-sw.template.js'), 'utf8')
    .replace('__BUILD_HASH__', 'test').replace('__PRECACHE__', JSON.stringify(['/index.html', '/main.dart.js']));
  vm.runInNewContext(source, context);
  function request(path, mode = 'cors', method = 'GET') {
    let response;
    handlers.fetch({ request: { url: `https://local.test${path}`, mode, method }, respondWith(promise) { response = promise; } });
    return response;
  }
  return { request, calls };
}

test('offline navigation loads the app shell; authenticated endpoints never enter the shell cache', async () => {
  const sw = worker();
  assert.equal(await (await sw.request('/', 'navigate')).text(), 'cached application');
  for (const path of ['/auth/me', '/sync/pull', '/media/a', '/wallets', '/admin', '/account', '/learning/courses', '/unknown']) {
    assert.equal(sw.request(path), undefined, path);
    assert.equal(sw.request(path, 'navigate'), undefined, path);
  }
  assert.equal(sw.request('/main.dart.js', 'cors', 'POST'), undefined);
  assert.deepEqual(sw.calls, ['/index.html']);
});

test('only enumerated immutable build assets are served from the app cache', async () => {
  const sw = worker();
  assert.equal(await (await sw.request('/main.dart.js')).text(), 'cached application');
  assert.deepEqual(sw.calls, [{ url: 'https://local.test/main.dart.js', mode: 'cors', method: 'GET' }]);
});
