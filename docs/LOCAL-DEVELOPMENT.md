# FarmerPlus local test architecture

This workspace is a testing system. It uses fresh email-based accounts and a new database. No old test data migration is required. The original Android source remains available until the PWA replacement has been validated.

| Project | Location | Responsibility |
| --- | --- | --- |
| Farmer PWA | `C:\Farmer PWA` | Installable browser app, farmer UI, local records, mapping, offline queues |
| Backend / Administration | `C:\Farmer Backend` | FastAPI, authentication, permissions, persistence, sync, map administration, integrations |
| Integration / Shared Contracts | `C:\Farmer Integration` | API schemas, shared identifiers, compatibility tests and change-impact documentation |
| eLearning | `C:\e-learning` | Independent Moodle / Studio project; authoritative learning services |
| Original Android app | `C:\Farmer App\mobile` | Preserved reference implementation, not the new PWA project |

The Integration project is not a backend. Application business rules stay with their owning application. Contract changes must identify their PWA, backend and eLearning consumers, update the contract, and run the affected compatibility checks.

## Start locally on Windows

Node.js 20 or newer and the existing Python environment at `C:\Farmer Backend\.venv` are required. The build script uses the existing Flutter SDK at `C:\e-learning\farmerplus-mobile\tooling\flutter`, falling back to Flutter on PATH.

```powershell
Set-Location 'C:\Farmer PWA'
npm run build
npm run dev
```

Open the PWA at <http://127.0.0.1:5173> and administration at <http://127.0.0.1:8088/admin>. The backend API is <http://127.0.0.1:8088>, with OpenAPI at `/openapi.json`. Use the exact same host (`127.0.0.1`) consistently. `localhost` has a separate browser storage and cookie context.

The local launcher serves the built PWA and forwards API requests to the backend on the PWA origin, retaining HttpOnly cookie authentication and same-origin write checks. It binds to loopback only. It fails if either port is occupied. Rebuild the PWA after Dart or web asset changes and reload the browser. Stop both services with Ctrl+C.

The launcher always uses `C:\Farmer Backend\.local-development\farmer.sqlite`, independent of the older backend's database. It does not reset this database on restart: records created during testing persist. It loads `C:\Farmer Backend\.env` into the backend process only. This file is ignored and must not be committed or copied into browser assets. See `C:\Farmer Backend\.env.example` for all provider settings.

```powershell
npm run test:backend
npm run test:integration
```

For standalone backend development, run `C:\Farmer Backend\Start-Dev.ps1`. It loads the backend's local `.env` and uses the same isolated development database as the combined launcher. Stop the combined launcher first to release port 8088.

## Authentication providers

The current authentication candidate opens Keycloak's branded sign-in form
directly after provider discovery, rather than showing a second button gateway.
The matching theme and registration-flow setting live in
`C:/Farmer Backend/identity/keycloak`. They must be released with the backend's
30-minute browser-flow fix; building the PWA alone does not update hosted forms.
The isolated review preview uses port 5184 and a separate disposable Keycloak
realm through loopback port 8185. It does not modify production identities.
See `C:/Farmer Integration/docs/authentication-journey-2026-09-27.md` for evidence
and the coordinated rollout boundary.

The PWA requires new email-based test accounts. SMTP2GO settings are backend-only; authentication emails are redirected in test mode while retaining the intended account email. `TEST_EMAIL_MODE=false` uses actual recipients. Production configuration must explicitly disable test routing; it must never silently inherit test defaults.

Google and Apple require registered provider applications and provider credentials. An unconfigured provider must be shown as unavailable, never as a simulated successful sign-in. Local automated tests cover validation and protocol handling; live provider login needs provider setup and an allowed callback URL. SMTP acceptance is distinct from confirmation that a message arrived in an inbox.

The loopback preview uses a separate confidential `farmerplus-local` client in the hosted FarmerPlus Keycloak realm, with the exact callback `http://127.0.0.1:5173/oidc/web/callback`. Its credential remains in the ignored backend `.env`. Keycloak registration and Google sign-in are full-page OIDC redirects. An ordinary web browser returns to its own browser origin. The Codex in-app browser may hand an external identity page to Chrome; PWA navigation code cannot control that host behavior.

The hosted Learning API validates tokens through the hosted backend. Until its optional `FARMER_PREVIEW_LEARNING_CLIENT_ID=farmerplus-local` approval is deployed, local preview accounts can provision and open Moodle online, but `/learning/courses` in the local preview returns 403. The proposed approval applies only to Moodle Learning introspection, not hosted farm API access. The staged eLearning changes in `C:\e-learning` are not deployed.

## Offline and location boundaries

Install or load the PWA while connected before attempting offline startup. Browser storage is scoped to the site and device. Persistent storage is requested where supported, but browsers and users can still clear site data. Save/export essential records before clearing it.

GPS does not itself require an internet connection. Accuracy depends on hardware, permission, satellite reception and the browser's location provider. Desktop browsers may return coarse network-derived locations. Boundary capture must show measured accuracy and reject poor or stale fixes, never imply survey accuracy. Browser suspension and screen locking can interrupt a walk; saved local drafts and explicit resume are required. Screen wake lock is best-effort and does not make background tracking reliable.

On desktop web, a verified online sign-in asks the browser for one fresh position using `navigator.geolocation.getCurrentPosition()` with `enableHighAccuracy: true`, `maximumAge: 0` and a 20-second timeout. The PWA checks age and reported accuracy, saves the fix, and queues the registration pin for backend sync. These options cannot force GPS hardware or guarantee the nearest or most precise coordinates. Weather stays off by default and this sign-in location check does not activate it.

Offline boundary editing and basemap availability are separate. A saved farm outline remains editable without a basemap. Offline basemaps need explicitly downloaded/imported, licensed data; public OpenStreetMap tiles must not be bulk downloaded. Saved maps remain until explicit removal, subject to browser storage limits or site-data clearing. Required map attribution remains accessible.

## CodeGraph

Use the indexed project root before code search. On this Windows host:

```powershell
& 'C:\Users\SteveMonty\AppData\Local\codegraph\current\bin\codegraph.cmd' explore 'SyncEngine sync'
```

Run it from the project you are inspecting. Each project index describes that project; shared contract documentation and tests make cross-project dependencies explicit. Do not treat a single graph as proof that browser behavior or an external provider works.

## Codex tasks from any project

Each project, the eLearning root, and the original Farmer App root now has an AGENTS.md with the same project map and cross-project workflow. Start Codex from any folder; it can find the owning code and use explicit working directories. The three new folders can be added separately using the Codex Add project control. Creating folders does not automatically register sidebar projects.
