# FarmerPlus Backend

This is the standalone FarmerPlus API and administration project. It owns server authentication, synchronisation, permissions, records, geospatial services, messaging, learning integration boundaries, reporting, and the map-first administrator workspace. The existing Android API contracts remain available while the PWA uses the new email and social-authentication contracts.

## Run locally

The combined local environment is started from `C:\Farmer PWA`:

```powershell
cd 'C:\Farmer PWA'
npm run dev
```

That serves the PWA at `http://127.0.0.1:5173`, the API at `http://127.0.0.1:8088`, and the administrator workspace at `http://127.0.0.1:8088/admin`.

To run this project by itself:

```powershell
cd 'C:\Farmer Backend'
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# Set SMTP2GO_PASSWORD in .env if authentication email delivery is needed.
.\Start-Dev.ps1
```

The `.env` file is ignored. `Start-Dev.ps1` loads it without printing values and always uses the same durable, isolated `.local-development\farmer.sqlite` database as the combined PWA launcher. It works from any current directory because it resolves all paths from the script location. `Start-Backend.ps1` remains available for custom local storage configured through `.env`. `docker compose up --build` runs the backend with PostgreSQL after `POSTGRES_PASSWORD` is set in `.env`.

## Authentication contracts

| Method and path | Purpose |
| --- | --- |
| `GET /auth/providers` | Truthful email, Google, and Apple configuration status |
| `POST /auth/email/register` | Create a new isolated email account and send verification |
| `POST /auth/email/verification/request` | Resend verification without account enumeration |
| `POST /auth/email/verification/confirm` | Consume a one-use verification token |
| `POST /auth/email/login` | Start the existing HttpOnly server session after verification |
| `POST /auth/email/password/forgot` | Send a one-use reset link without account enumeration |
| `POST /auth/email/password/reset` | Replace password and revoke existing sessions |
| `GET /auth/social/{provider}/start` | Begin configured Google or Apple OIDC authorization |
| `GET/POST /auth/social/{provider}/callback` | Verify provider callback and establish the server session |
| `GET /auth/me` | Return the authenticated owner, account kind, and credential epoch |
| `POST /auth/logout` | Revoke the current session |

New email and social accounts never auto-link an older username account merely because profile emails match. The older `/auth/register`, `/auth/login`, recovery-code, offline verification, sync, media, catalogue, package, learning, map, and administration APIs remain intact.

Email verification tokens expire after 24 hours. Password reset tokens expire after 30 minutes. Only token hashes are stored. Reset revokes existing sessions and changes the credential epoch. SMTP delivery evidence records the intended recipient, actual outbound recipient, purpose, test-mode status and result; it never stores the token or message body.

`TEST_EMAIL_MODE=true` redirects authentication mail to `TEST_EMAIL_RECIPIENT` while retaining the intended account email. The backend refuses to start with test routing enabled when `FARMER_ENVIRONMENT=production`. SMTP2GO credentials are environment-only. An empty password reports email as unconfigured and mail endpoints fail closed.

Google and Apple buttons remain disabled until their client ID and client secret pairs are configured. Both use provider discovery, authorization code flow, state and nonce verification through Authlib. Apple additionally requires an HTTPS `FARMER_PUBLIC_URL` because its verified callback uses `form_post`. No local test pretends an unconfigured provider succeeded.

## Administrator access

The default administrator page is the operations map. It combines mapped farms and fields, clustering, boundary selection, layers, filters, place and farmer search, record drill-down, contextual panels, exports, and map-to-record navigation. Existing work queues, data quality, learning, communications, sources, reports and audit views remain available.

The hosted backend uses `FARMER_ADMIN_LOCAL_LOGIN=1`. Its Username/Password form at
`/admin/login` uses independent administrator credentials and sessions. Mobile and
Learning retain their own authentication. Provision the sole operator with
`scripts/provision_admin_login.py`, passing a JSON object containing `username` and
`password` on standard input in the backend's configured environment. This revokes
previous administrator sessions and roles while retaining farmer data. No password
is embedded in the source or frontend. Production cookies require HTTPS.

For development with independent admin login disabled, register and verify a test
email account, then grant or revoke local administrator access with:

```powershell
.\Manage-Dev.ps1 grant-email-admin operator@example.test
.\Manage-Dev.ps1 revoke-email-admin operator@example.test
```

`Manage-Dev.ps1` loads the backend `.env` without printing values and forces the same ignored `.local-development\farmer.sqlite` database used by `Start-Dev.ps1` and the combined PWA launcher. It resolves paths from its own location, so the command works from any current directory. These legacy email and username administrator grants apply when independent login is disabled.

The App store is under **Management → App store** (`/admin#apps`). Register apps,
upload versioned packages, validate, publish or retire releases, and inspect device
installation reports. Production requires a persistent `FARMER_MINIAPP_SIGNING_KEY`
and its public key in the mobile `assets/miniapps/trust.json`. Never distribute the
private key. The gateway preserves all `/api/v1/` package and shared farm API paths.

## Configuration

Use `.env.example` as the complete local template. The main groups are:

- server and storage: `FARMER_ENVIRONMENT`, `FARMER_DATA_DIR`, `DATABASE_URL`, `FARMER_PUBLIC_URL`, `FARMER_PWA_PUBLIC_URL`, `FARMER_SECURE_COOKIES`;
- SMTP2GO: `SMTP2GO_HOST`, `SMTP2GO_PORT`, `SMTP2GO_USERNAME`, `SMTP2GO_PASSWORD`, `SMTP_FROM_EMAIL`, `SMTP_FROM_NAME`;
- test delivery: `TEST_EMAIL_MODE`, `TEST_EMAIL_RECIPIENT`;
- upstream OIDC: `GOOGLE_OIDC_CLIENT_ID`, `GOOGLE_OIDC_CLIENT_SECRET`, `APPLE_OIDC_CLIENT_ID`, `APPLE_OIDC_CLIENT_SECRET`, `FARMER_OAUTH_SESSION_SECRET`;
- optional existing integrations: the `FARMER_*` provider, Moodle, map and tenant settings referenced by their administration source setup pages.

The bundled offline package manifests are owned by `resources/packs`; the backend no longer reads assets from the mobile project.

## Verification

```powershell
.\.venv\Scripts\python.exe -m pytest tests -q
node --test tests\*.test.cjs
```

`scripts/verify_smtp_delivery.py` is an explicit live-delivery check and sends real messages. Do not run it as part of routine tests. The recorded local test evidence is in `evidence/smtp-delivery.json`.

The local backend supports SQLite for simple development and PostgreSQL through Compose. Google and Apple cannot be live-verified until provider credentials and registered redirect URIs exist. Moodle and other external provider behavior is only available when its separate credentials are configured.
