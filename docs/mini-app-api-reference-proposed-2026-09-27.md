# FarmerPlus mini-app API reference

**27 September 2026 · Proposed contract catalogue · No new API is implemented**

This lists every interface proposed by the [My Animals plan](my-animals-plan-2026-09-27.md), plus the existing interfaces it would reuse. It is a future reference for similar mini-apps, not an exhaustive inventory of unrelated administration, wallet, mapping or learning endpoints.

**Status legend:** Existing = verified in current source; Extend = new behaviour/schema planned around an existing facility; Proposed = requires implementation. Paths and method names below are design decisions to formalise in Farmer Integration before coding. New farmer-facing HTTP routes use `/api/v1`; administration extends the existing `/admin/api/v2` namespace. New SDK calls use `FarmerPlus SDK v1`.

## 1. Interface layers

| Layer | Used by | Responsibility |
|---|---|---|
| Host SDK | Downloaded My Animals and future mini-apps | Offline access, approved shared data, native host pickers, theme/navigation, scoped commands |
| Platform HTTP APIs | PWA host | Discover/download releases, read shared reference data, synchronise app-owned records and submit durable commands |
| Administration HTTP APIs | Backend Apps UI | Register, validate, release and retire app packages |
| Animal command contract | My Animals through the host; Backend validator | Count, movement, history and profile rules |

The downloaded package does not receive unrestricted HTTP access or credentials. The PWA host is the bridge. Server routes always validate the current account and registered app capabilities; client-provided app IDs are not evidence of authorisation.

## 2. Existing interfaces to reuse

| Status | Method and path / component | Purpose and limits |
|---|---|---|
| Existing | `GET /auth/me` | Host establishes current authenticated owner/account context. Mini-app gets only an approved subset. |
| Existing | Host OIDC/session and offline-unlock flow | Authentication remains host-managed; My Animals has no login form or password store. |
| Existing | `POST /sync/push` | Existing single shared-record mutation with `op_id` and `base_version`; used by host farm/area edits. Not sufficient for a two-group animal transfer. |
| Existing | `GET /sync/pull` | Existing owner-scoped shared records, including deletion markers. Preserve legacy semantics. |
| Existing / Extend | `POST /sync/complete` | Existing installed-app inventory; extend capability reporting only additively and test consumers. |
| Existing | `GET /media/{hash}/status` | Find accepted byte offset/completion before resume. |
| Existing | `PUT /media/{hash}` | Upload resumable base64 chunk with offset/total; server verifies complete SHA-256. |
| Existing | `GET /media/{hash}?offset=…` | Read owner-authorised verified media in chunks. Host also checks app-record linkage. |
| Existing | `GET /catalogue` | Legacy package catalogue. Preserve existing non-executable package contract. |
| Existing | `GET /packages/{id}/{version}?offset=…` | Legacy JSON chunk response with total/hash. Reuse transport experience, not implicit executable trust. |
| Existing | `PATCH /admin/packages/{id}/{version}?active=…` | Legacy package activation. Keep separate from new release approval/signature checks. |
| Existing / Extend | `FarmStore`, `BrowserPwaStore`, `SyncEngine` | Existing owner-bound storage/queue; extend with app data and atomic command transactions. |
| Existing / Extend | `MiniAppSession`, `MiniManifest` | Existing compiled-app facade/permissions; keep compatibility while introducing the new SDK. |

These paths are relative to the configured backend. Current PWA deployment/proxy handles cookies and same-origin write checks. Preserve its authentication rules; no authentication secrets belong in packages or API examples.

## 3. Proposed host SDK: shared services

Every entry in this section is **Proposed**. Read calls work from authorised local data when offline and include freshness information. Writes resolve only after durable local storage, returning sync status separately.

| SDK method | Returns / action | Permission and offline behaviour |
|---|---|---|
| `context.get()` | App instance, SDK version, owner reference, selected farm, locale, timezone, units, online state, approved capabilities | Minimal context; available after host unlock |
| `context.subscribe(handler)` | Account/farm/locale/connectivity changes; returns unsubscribe function | Account change invalidates the instance instead of exposing another account |
| `theme.get()` | Semantic colours, typography, spacing, radii, control sizes, text scale, brightness and reduced-motion setting | Presentation only; cached |
| `theme.subscribe(handler)` | Theme/accessibility changes | Available offline |
| `farmer.getProfile()` | Approved farmer display name and preferences | `profile.read`; omit email/private fields unless separately required |
| `farms.list({cursor,limit})` | Accessible shared farms | `farms.read`; local cache |
| `farms.get(farmId)` | Shared farm ID, name, metadata and version | `farms.read`; no duplicated farm object |
| `farms.choose({initialId})` | Host farm picker; chosen ID or cancelled | `farms.read`; offline cached choices |
| `farms.create()` | Opens existing host farm editor, returns saved ID or cancelled | `farms.create`; host confirmation through ordinary form save; queued offline |
| `locations.list({farmId,types,cursor,limit})` | Shared areas with `id`, `farmId`, name, type and version | `locations.read`; maps to existing `field` records |
| `locations.get(locationId)` | Shared area details | `locations.read`; owner/farm validated |
| `locations.choose({farmId,initialId,allowUnknown})` | Searchable host picker, explicit unknown or cancelled | `locations.read`; no GPS request needed |
| `locations.create({farmId})` | Existing area editor, returns shared ID | `locations.create`; optional mapping; no duplicate mini-app place table |
| `navigation.open({route,params})` | Open an allowlisted host route, such as an existing farm/area | `navigation.open`; reject arbitrary URLs |
| `navigation.back()` | Return through current mini-app/host history | Host-managed; offline |
| `navigation.closeApp()` | Return to FarmerPlus Home with draft protection | Host-managed; offline |
| `navigation.setDirty({dirty,draftId})` | Tell host about unsaved form state | No data write by itself; pair with durable draft |
| `media.choosePhoto({source})` | Host camera/file picker, validates file, saves local bytes, returns hash/preview handle | `media.write`; permission only after explicit user action |
| `media.getPreview(hash)` | Short-lived preview for an app-authorised attachment | `media.read`; cached locally or downloaded through host |
| `media.releasePreview(handle)` | Release temporary resources | Offline; does not delete the attachment |
| `drafts.get(key)` | App/owner/farm-bound form draft | `drafts`; offline |
| `drafts.put(key,data)` | Durable bounded draft | `drafts`; offline; no global settings access |
| `drafts.remove(key)` | Remove a completed/discarded draft | `drafts`; offline; never removes animal history |
| `sync.getStatus()` | Pending operations/media, last success, connectivity and conflicts for this app | `sync.read`; no unrelated app data |
| `sync.subscribe(handler)` | Changes to the app's sync state | `sync.read`; returns unsubscribe |
| `sync.request()` | Ask host scheduler to send queued work | `sync.request`; reports offline/locked/auth-required truthfully |
| `storage.estimate()` | App footprint and browser capacity estimate when available | `storage.read`; an estimate is not a reservation |
| `exports.create({format,filters})` | Host-generated JSON/CSV file of authorised app data | `export`; offline for cached records; never automatic sharing |

UI bridge also supports focus return after a host picker, safe-area/keyboard inset updates and host back-button handling. These are runtime integration events, not additional farmer-data permissions.

## 4. Proposed host SDK: app data

All access is restricted to registered kinds and the active app/owner. There is deliberately no unrestricted `database.execute`, `fetch`, global settings setter or arbitrary multi-record write.

| SDK method | Purpose |
|---|---|
| `records.list({kind,filters,cursor,limit})` | Search authorised app records with app-local indexing and pagination |
| `records.get({kind,id})` | Read one record and its version/sync state |
| `records.subscribe({kind,filters},handler)` | Update a view after local changes or sync; unsubscribe on close |
| `catalogues.get({name,version})` | Versioned animal types and breed catalogue, merged with authorised custom entries |
| `commands.preview({name,payload,expectedVersions})` | Run installed rule version against current local data; return before/after effects, warnings and dependencies |
| `commands.enqueue({operationId,name,payload,expectedVersions,ruleVersion})` | Atomically persist command, local projection and queue entry; returns provisional local result and sync state |
| `commands.get(operationId)` | Current local result, server receipt, retry/error/conflict status |
| `conflicts.list()` | Unresolved app command conflicts |
| `conflicts.resolve({operationId,choice,replacement})` | Keep server state or review/rebase as a new command; retains the rejected proposal for audit/recovery |

Package code supplies deterministic local animal rules; the backend independently validates the same contract. Shared fixtures check their agreement. Local preview is provisional because another device may change the server state before sync. The host limits operation size/kinds and stores each command plus projection atomically, but backend rules remain the authority.

## 5. Proposed platform HTTP APIs

### App Store and packages

| Method and route | Purpose / response |
|---|---|
| `GET /api/v1/apps` | Paginated catalogue of authorised published apps, compatibility and offline capabilities |
| `GET /api/v1/apps/{appId}` | Store detail, icon metadata, latest compatible release and permissions |
| `GET /api/v1/apps/{appId}/releases` | Available immutable release metadata for this client |
| `GET /api/v1/apps/{appId}/releases/{version}/manifest` | Signed manifest, total bytes, digest, signature/key ID, file list, SDK/data/command versions |
| `GET /api/v1/apps/{appId}/releases/{version}/package?offset=…` | Bounded base64 chunk, accepted offset, total, next offset and digest; raw decoded bytes define download progress |
| `PUT /api/v1/apps/{appId}/installations/{installationId}` | Idempotent device report: version, Downloading/Installed/Failed/Removed, approved grants, timestamp |

The proposed package endpoint deliberately mirrors the existing chunk protocol for predictable resume. Offset and version cannot change within a job; reject mismatched digest, invalid offset or retired/unavailable release. A resumed client verifies saved chunks before counting them. Return the store icon as a bounded safe image payload/metadata in catalogue/detail; full assets are in the verified package.

### Shared context reads

| Method and route | Purpose / response |
|---|---|
| `GET /api/v1/platform/context` | Minimal authenticated context, supported SDK versions, app capabilities and preferences |
| `GET /api/v1/farmer/profile` | Approved profile fields; existing identity remains authoritative |
| `GET /api/v1/farms` | Paginated farms accessible to the owner |
| `GET /api/v1/farms/{farmId}` | One shared farm and current version |
| `GET /api/v1/farms/{farmId}/locations` | Shared `field` records rendered as animal locations; filter by area type |
| `GET /api/v1/locations/{locationId}` | One location, its parent farm and version |

These are typed facades over existing records, not new stores. Farm and location creation/editing continue through host editors and existing shared-record sync. Backend permission checks follow current ownership; this proposal does not silently add collaborative access to other farmers' records.

### App records and atomic commands

| Method and route | Purpose / response |
|---|---|
| `GET /api/v1/apps/{appId}/catalogues/{name}` | Approved type/breed catalogue plus account custom entries, version/ETag |
| `GET /api/v1/apps/{appId}/records` | Paginated app-owned records; registered kind/filter allowlist |
| `GET /api/v1/apps/{appId}/records/{kind}/{id}` | One current record/projection and version |
| `GET /api/v1/apps/{appId}/changes?cursor=…&limit=…` | Incremental app data, revisions and tombstones; stable opaque next cursor |
| `POST /api/v1/apps/{appId}/commands/preview` | Optional online preview under current server state; never required for offline saving |
| `POST /api/v1/apps/{appId}/commands` | Validate and apply a named domain command in one transaction; return all resulting records and receipt |
| `GET /api/v1/apps/{appId}/commands/{operationId}` | Fetch receipt after a lost response; retry of identical command is also safe |

Animal records use this app namespace rather than injecting unsupported kinds into legacy `/sync/pull`. Host sync schedules shared farm/area parents first, media prerequisites next, then dependent animal commands. An unsynced new location is usable locally, but its animal command waits for parent acceptance on the server.

## 6. Proposed Backend Apps administration APIs

Follow existing administration role, reauthentication, CSRF and audit conventions. Ordinary farmer accounts cannot use these routes.

| Method and route | Purpose |
|---|---|
| `GET /admin/api/v2/apps` | App registry with icon, date, version, status and size |
| `POST /admin/api/v2/apps` | Register stable app ID and initial metadata |
| `GET /admin/api/v2/apps/{appId}` | Full app metadata and release overview |
| `PATCH /admin/api/v2/apps/{appId}` | Edit store metadata; cannot mutate released package bytes |
| `GET /admin/api/v2/apps/{appId}/releases` | Release history, compatibility and validation results |
| `POST /admin/api/v2/apps/{appId}/releases` | Upload immutable candidate artifact and declared manifest |
| `POST /admin/api/v2/apps/{appId}/releases/{version}/validate` | Verify contents, size, hash, schema, capabilities, compatibility and signature readiness |
| `POST /admin/api/v2/apps/{appId}/releases/{version}/publish` | Explicitly publish validated release and signed manifest |
| `POST /admin/api/v2/apps/{appId}/releases/{version}/retire` | Stop offering new installs; preserve records and audit |
| `POST /admin/api/v2/apps/{appId}/releases/{version}/rollback` | Select a validated compatible prior release for distribution; never force unsafe client downgrade |
| `GET /admin/api/v2/apps/{appId}/installations` | Permission-filtered device-reported states with last-seen time |
| `GET /admin/api/v2/apps/{appId}/audit` | Metadata, validation, publication, retirement and rollback history |

Publication is a future operator action, not authorised by the present planning request. Upload endpoints require hard size limits, safe archive handling or a constrained package format, and no execution during unpacking.

## 7. My Animals command catalogue

Stable app ID: **`my-animals`**. Registered record kinds: `animal`, `animalGroup`, `animalEvent`, `animalEventRevision`, `animalType`, `animalBreed`. Opening balances and movements are events; counts are validated projections. Standard catalogue entries are package/version data; account custom entries are owned records.

All commands below use the single command transport in section 5. They are not separate HTTP endpoints.

| Command | Input and result |
|---|---|
| `animals.createIndividual` | Farm, location or explicit unknown, species, name/tag, optional details; creates individual and opening event |
| `animals.createGroup` | Farm, location/unknown, species, name, positive count, optional details; creates group and opening balance |
| `animals.updateProfile` | Expected profile version; name/tag/breed/sex/age/photo/purpose/source/notes; excludes direct count and location changes |
| `animals.archive` | Archive an empty group or inactive individual; active animals must depart through a recorded event |
| `animals.restore` | Restore an erroneously archived eligible profile; does not silently reverse a sold/dead/lost event |
| `animals.removeMistakenProfile` | Reason and previewed dependencies; reversible tombstone and opening-event void when safe |
| `animals.identifyFromGroup` | Source group, new individual ID/profile and date; subtract one anonymous animal and add one individual atomically |
| `events.recordAddition` | Group, reason born/hatched/bought/added, quantity and date; increases count |
| `events.recordDeparture` | Subject(s), sold/transferred/died/lost/other, quantity/date; reduces group or inactivates individual |
| `events.recordReturn` | Eligible previously departed subject, date and reason; audited reactivation/addition, with dead-state corrections handled explicitly |
| `events.recordMove` | Source, destination farm/location, quantity or individual, target/new group, expected versions and date; atomic transfer |
| `events.recordWeight` | Subject, value, unit, individual/group-total/group-average basis, date and optional sampled count |
| `events.recordCare` | Completed care/treatment text, date, affected count, optional quantities/units/photo/notes |
| `events.recordObservation` | Reported observation, date, affected count, optional photo and notes |
| `events.recordNote` | Subject, date, note and optional photo |
| `events.correctCount` | Group, observed absolute count, effective date/order and reason; recompute and validate subsequent balances |
| `events.correct` | Target event/revision, replacement details and reason; immutable revision and atomic recomputation |
| `events.void` | Target event/revision and reason; audit-preserving removal with dependency checks |
| `options.createBreed` | Species and custom breed name; normalise/resolve duplicates without rewriting historical labels |
| `options.renameBreed` | Custom breed ID/version and corrected label; retain audit and historical snapshots |
| `options.retireBreed` | Remove custom choice from new-entry pickers; retain referenced data |
| `options.createType` | Custom species/type name; preserve five standards |
| `options.renameType` | Custom type ID/version and label; retain stable ID and audit |
| `options.retireType` | Hide custom choice from new-entry pickers; retain historical references |

Corrections to an opening balance are supported through the event correction workflow. “Remove record” in the UI maps to `events.void`, not hard deletion. Restore of a voided event is a new validated revision and must recheck all dependent balances. Backend rejects custom-option mutation of protected standard entries.

## 8. Common data contract

### IDs and ownership

- Account, farm, field/location, animal/group, event, operation, installation and device IDs are UUIDs using existing project conventions. App IDs are stable slugs. Media hashes are lowercase SHA-256 strings.
- The authenticated principal determines owner. Payloads cannot select another owner. Every referenced parent, destination and attachment is authorised.
- Type/breed IDs are stable catalogue keys for built-ins and UUIDs for custom choices; document the tagged union so a display name is never an identifier.
- Preserve existing `farm`/`field` IDs. A location response can label a field as a Pen or Poultry house without introducing another identity.

### Record envelope

Common fields: `id`, `kind`, `appId`, `farmId`, `version`, `deleted`, `updatedAt`, `data`. The server binds owner internally. Local SDK adds `syncState`, `pendingOperationIds` and `lastSyncedAt` without pretending those are authoritative server fields.

Event data includes effective date, optional time/timezone, deterministic same-day order, subject/source/destination IDs, quantity/units, reason, notes, media hashes and historical name/location snapshots. Audit includes original author, server recorded time and revision linkage. Preserve local entered time separately when useful.

### Command envelope

```json
{
  "operationId": "UUID",
  "deviceId": "UUID",
  "schemaVersion": 1,
  "ruleVersion": 1,
  "name": "events.recordMove",
  "expectedVersions": {"sourceGroupUUID": 7, "destinationGroupUUID": 2},
  "dependsOn": [],
  "payload": {
    "sourceGroupId": "sourceGroupUUID",
    "destinationGroupId": "destinationGroupUUID",
    "destinationLocationId": "sharedFieldUUID",
    "quantity": 10,
    "occurredOn": "2026-09-27"
  }
}
```

The UUID strings are illustrative placeholders, not valid fixture values. Include all affected entity versions plus necessary parent/reference versions in a real command. For a new destination, allocate its stable UUID locally and use expected version zero. `dependsOn` names earlier queued operation IDs; block descendants when a prerequisite is rejected.

The server records operation ID plus canonical payload digest under owner/app scope. Identical retries return the same receipt. Reusing an ID with changed content returns conflict. Profile, event, source balance, destination balance, change cursor entries and receipt commit together or all roll back. Serialize/check affected records in a stable order to prevent concurrent negative counts.

### Response and errors

Success returns `{operationId, status, changedRecords, receipt, serverTime}`. An SDK local save returns `status: "queued"`; server acceptance returns `status: "applied"`. UI may say Saved on this device while pending, then Synced after acceptance.

Proposed error shape: `{code, message, fieldErrors, retryable, conflictRecords, requestId}` with no sensitive debug details.

| Status / code | Meaning and UI behaviour |
|---|---|
| 401 `authentication_required` | Ask host to reconnect; preserve queued work |
| 403 `capability_denied` | App lacks permission; do not retry forever |
| 404 `not_found` | Unavailable/inaccessible resource without leaking another owner's existence |
| 409 `version_conflict` | Review full atomic change against current records |
| 409 `operation_mismatch` | Operation ID reused with different payload |
| 409 `dependency_conflict` | Earlier/later event prevents consistent replay |
| 413 `size_limit` | Explain allowed attachment/package size |
| 416 `invalid_offset` | Restart/resume from verified accepted offset |
| 422 `validation_failed` | Field errors, invalid dates/counts or incompatible package/command schema |
| 429 `rate_limited` | Respect Retry-After; retain queue |
| 5xx / network failure | Bounded backoff with jitter; retry same operation ID |
| Local `storage_full` | Preserve existing state; explain space required; do not claim save succeeded |

### Pagination, sync and versioning

Default read page 50, maximum 200; stable sorting and opaque cursor. The change feed must retain tombstones long enough for supported offline clients; an expired cursor returns a resnapshot requirement that preserves queued work and reconciles before replay.

A transaction's changed records must be applied atomically on pull as well as push. Change pages carry transaction IDs, completeness markers and a cursor only after complete transaction boundaries. Clients stage oversized transaction fragments until complete. Never display a source decrement without its matching destination increment.

HTTP major version, SDK major version, command schema, data schema, rule version and app release version are distinct. Additive optional fields can be compatible; required-field/meaning changes need coordinated versioning. Server supports queued commands from documented supported package versions; unsupported versions receive a clear update path without discarding unsynced data.

## 9. Future reference and implementation outputs

Place the final normative contract in **Farmer Integration**, including OpenAPI for HTTP, SDK types, JSON schemas, example fixtures and a consumer matrix. Generate the reference from contracts where practical so names do not drift. Keep animal business implementation in Backend and its reviewed package source.

Required contract fixtures: complete install/resume, invalid signature, unavailable release, owner mismatch, offline new farm/area dependency, duplicate command, transfer, conflicting transfer, count correction, event void, grouped-animal identification, photo-before-record ordering, package rollback and legacy sync compatibility.

This document is the complete proposed catalogue for this scope. Production URLs, final schemas, signing keys and published release versions are deliberately not invented. No endpoint availability, runtime security or device behaviour is claimed until implemented and verified.
