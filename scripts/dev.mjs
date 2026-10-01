// Local-only orchestration. Secrets stay in the backend child environment.
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync, readFileSync, createReadStream, statSync, mkdirSync } from 'node:fs';
import { spawn } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const webRoot = path.join(root, 'build', 'web');
const backendRoot = process.env.FARMER_BACKEND_DIR || path.resolve(root, '..', 'Farmer Backend');
const apiPort = 8088;
const pwaPort = 5173;
const python = process.env.FARMER_PYTHON || path.join(backendRoot, '.venv', 'Scripts', 'python.exe');
const backendEnv = { ...process.env };
const envPath = path.join(backendRoot, '.env');
if (existsSync(envPath)) {
  for (const raw of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const match = raw.match(/^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!match) continue;
    let value = match[2];
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
    backendEnv[match[1]] = value;
  }
}
const localData = path.join(backendRoot, '.local-development');
mkdirSync(localData, { recursive: true });
// Deliberately isolated from the existing Android test backend's database.
backendEnv.FARMER_DATA_DIR = localData;
backendEnv.DATABASE_URL = `sqlite:///${path.join(localData, 'farmer.sqlite').replaceAll('\\', '/')}`;
backendEnv.FARMER_SECURE_COOKIES = '0';
backendEnv.FARMER_PUBLIC_URL ??= 'http://127.0.0.1:8088';
backendEnv.FARMER_PWA_PUBLIC_URL ??= 'http://127.0.0.1:5173';
backendEnv.SMTP_FROM_EMAIL ??= 'noreply@farmerplus.earth';
backendEnv.TEST_EMAIL_MODE ??= 'true';
backendEnv.TEST_EMAIL_RECIPIENT ??= 'steve@informationcapital.co.za';

async function requireFreePort(port) {
  await new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.once('error', () => reject(new Error(`Port ${port} is already in use; stop its service before starting this workspace.`)));
    probe.listen(port, '127.0.0.1', () => probe.close(resolve));
  });
}
if (!existsSync(python)) throw new Error('Backend Python missing. Create .venv in Farmer Backend and install its requirements.txt.');
if (!existsSync(path.join(webRoot, 'index.html'))) throw new Error('Build the PWA first: npm run build:pwa');
await requireFreePort(apiPort);
await requireFreePort(pwaPort);

const mime = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.wasm': 'application/wasm', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.webp': 'image/webp', '.ttf': 'font/ttf', '.woff2': 'font/woff2' };
const proxyRoots = new Set(['account', 'auth', 'oidc', 'sync', 'media', 'catalogue', 'packages', 'learning', 'community', 'notifications', 'sharing', 'coops', 'map', 'maps', 'admin', 'login', 'logout', 'health', 'static', 'api', 'tenants', 'wallets', 'files', 'estimate', 'prepare', 'jobs']);
const server = http.createServer((request, response) => {
  let pathname;
  try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
  catch { response.writeHead(400).end('Invalid URL'); return; }
  const segment = pathname.split('/')[1];
  const pwaAuthRoute = ['/auth/verify', '/auth/reset', '/auth/callback'].includes(pathname);
  if (proxyRoots.has(segment) && !pwaAuthRoute) {
    const apiPath = segment === 'api' && !pathname.startsWith('/api/v1/') ? request.url.replace(/^\/api(?=\/|\?|$)/, '') || '/' : request.url;
    // Retain the browser Host so the backend's same-origin CSRF boundary holds.
    const upstream = http.request({ hostname: '127.0.0.1', port: apiPort, path: apiPath, method: request.method, headers: request.headers }, incoming => {
      response.writeHead(incoming.statusCode, incoming.headers);
      incoming.pipe(response);
    });
    upstream.on('error', () => { if (!response.headersSent) response.writeHead(502, { 'Content-Type': 'application/json' }); response.end('{"detail":"Local backend unavailable; saved work stays on this device."}'); });
    request.on('aborted', () => upstream.destroy());
    request.pipe(upstream);
    return;
  }
  if (!['GET', 'HEAD'].includes(request.method)) { response.writeHead(405).end(); return; }
  let candidate = path.resolve(webRoot, `.${pathname}`);
  if (!candidate.startsWith(webRoot + path.sep) && candidate !== webRoot) { response.writeHead(403).end(); return; }
  if (pathname.endsWith('/')) candidate = path.join(candidate, 'index.html');
  if (!existsSync(candidate) || !statSync(candidate).isFile()) {
    if (path.extname(pathname)) { response.writeHead(404).end('Not found'); return; }
    candidate = path.join(webRoot, 'index.html');
  }
  response.writeHead(200, { 'Content-Type': mime[path.extname(candidate)] || 'application/octet-stream', 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff', 'Service-Worker-Allowed': '/', 'Referrer-Policy': 'strict-origin-when-cross-origin' });
  if (request.method === 'HEAD') response.end(); else createReadStream(candidate).pipe(response);
});
const backend = spawn(python, ['-m', 'uvicorn', 'app:app', '--host', '127.0.0.1', '--port', String(apiPort), '--no-access-log'], { cwd: backendRoot, env: backendEnv, stdio: 'inherit', windowsHide: true });
let closing = false;
function close(code = 0) {
  if (closing) return;
  closing = true;
  server.close();
  backend.kill();
  setTimeout(() => process.exit(code), 300).unref();
}
backend.on('error', error => { console.error(`Backend could not start: ${error.message}`); close(1); });
backend.on('exit', code => { if (!closing) close(code || 0); });
process.on('SIGINT', () => close());
process.on('SIGTERM', () => close());
server.listen(pwaPort, '127.0.0.1', () => {
  console.log(`Farmer PWA: http://127.0.0.1:${pwaPort}`);
  console.log(`Administration: http://127.0.0.1:${apiPort}/admin`);
  console.log(`API: http://127.0.0.1:${apiPort} (also proxied through the PWA origin)`);
  console.log(`Local test data: ${localData}. Ctrl+C stops both services.`);
});
