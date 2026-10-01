# FarmerPlus Keycloak identity

Decision: operate a **separate `farmerplus` realm**. Keycloak owns email/password,
email verification, recovery, MFA and Google/Apple brokerage. The PWA and Moodle
are confidential OIDC clients of this realm. The wallet provider remains a
separate relying party or broker relationship; using Keycloak on both sides does
not itself establish wallet SSO or authorize financial transactions.

## What runs

`keycloak_identity.py` replaces Hydra routes when `FARMER_IDENTITY_PROVIDER=keycloak`
and the issuer is supplied. Missing required secrets stop startup. With no issuer,
the existing isolated local-development authentication remains available; this is
not an activated Keycloak deployment. Legacy Hydra can only be chosen explicitly.

The backend keeps tokens encrypted and browser cookies HttpOnly. Authlib owns the
authorization-code, S256 PKCE, state/nonce and RS256 checks. Every protected API
request introspects against the configured realm and verifies issuer, audience,
client, scope, expiry, stable identity and local revocation. No password grant or
implicit flow is used. Legacy credential endpoints are blocked in Keycloak mode.

Account owners are derived from `(realm issuer, Keycloak subject)`. The immutable
32-character FarmerPlus ID is stored in a Keycloak attribute editable only by
administrators, then included in PWA/Moodle tokens by a mapper. Email is never an
account merge key. Keep the realm issuer stable. Existing production identities
must be explicitly linked/migrated; do not overwrite issuer/subject mappings or
silently merge by email. This workspace uses fresh test accounts.

Every 15 seconds, a paginated worker reconciles verified realm users, including
Google/Apple registrations and registrations whose browser never returns. In one
database transaction it creates/updates the local identity and durable Learning
outbox. Delivery has a lease, bounded retries and increasing delay (up to one hour).
Registration can complete during a Moodle outage. Provisioning status is
`pending`, `ready`, or `needs_attention` after ten failed deliveries; retries
continue. This is asynchronous registration-time provisioning, not synchronous
enrolment. Larger realms should replace full reconciliation with a durable event
feed plus periodic reconciliation after measuring their size/load.

The Moodle endpoint uses the existing locked OIDC identity resolver, verifies the
deployment's issuer/tenant/instance, updates names and verified email, and records
monotonic revisions. Duplicate/reordered delivery cannot create another account
or overwrite newer profile data. It does not enrol courses, assign roles, copy
passwords, grant paid content, change grades or alter wallets.

## Deployable configuration

Learning journey candidate (27 September): `keycloak_identity.py` accepts a
state-bound `destination=learning` plus optional numeric `cmid`. After the existing
verified identity preparation it returns to Moodle's independent OIDC flow. Default
PWA return behavior is unchanged. Release instructions and the fresh Moodle diff
are in `C:/e-learning/.server-edit/auth-journey-20260927/ROLLOUT.md`; the old Moodle
candidate path below must not be uploaded wholesale for this journey. See the
Integration `docs/learning-authentication-journey-2026-09-27.md` contract.

### Mobile authentication theme candidate (27 September)

The image now includes the existing FarmerPlus wordmark/farm backdrop theme.
New realm generation selects it and collects passwords during registration,
while retaining required email verification. For an existing realm, install the
image first, then use the narrow, idempotent upgrade (never reimport the realm):

```powershell
.venv/Scripts/python.exe -m identity.keycloak.upgrade_registration --issuer https://auth.agritec.earth/realms/farmerplus --token-file <private-operator-token-file>
```

This invocation only reviews. After deployment approval, add `--apply --backup-dir
<private-backup-directory>`. Use a short-lived operator token with realm/auth-flow
management permissions, not the provisioning client's limited token. Keep
backups private. Revert only the saved realm fields, execution config and profile
on rollback; retain the previous image and PWA build. Release `keycloak_identity.py`,
`oidc.py` and the PWA direct landing together. The callback lifetime is 1,800
seconds; state plus browser binding selects each single-use tab flow.

See `themes/farmerplus/README.md` for asset provenance and the Keycloak 26.7.4
password-setting compatibility flag. Source and isolated preview verification
do not imply a public deployment. Moodle's other staged platform changes remain
separate from this authentication-theme candidate.

1. Use Keycloak **26.7.4** (version checked against its published release), a
   supported Java runtime, PostgreSQL, persistent storage and an HTTPS hostname.
   Local smoke testing uses a disposable loopback development instance; do not
   publish `start-dev`, its H2 database or its bootstrap account.
2. Supply PWA and Learning HTTPS origins and the three client secrets in a secret
   store/environment. Run `python identity/keycloak/realm.py --output <private>/farmerplus-realm.json`.
   Import that realm once. The rendered file contains secrets: keep it outside web
   roots and source control. Never re-import over an existing realm as an upgrade.
3. Configure realm SMTP in Keycloak. The backend's SMTP2GO test-recipient override
   does not apply to Keycloak; use an isolated mail sink/test mailbox in staging.
   Keep email verification and required first/last names enabled. Keep the default
   first-broker login flow requiring ownership proof before linking an existing
   account. Do not enable automatic email-based linking.

   On the current production test architecture, the operator requested that
   Keycloak verification and reset messages be delivered to the private test inbox
   while users' account email addresses stay unchanged. The `mail-relay` service in
   `compose.agritec.yaml` accepts mail only from the Keycloak container and rewrites
   the SMTP recipient to the configured test inbox. Its protected configuration is
   `private/mail-relay.json`, mounted read-only; it is never built into an image.
   The live realm SMTP points at `mail-relay:1025`. This is a temporary exception
   for the approved test phase: users cannot receive their own verification/reset
   messages until the operator ends it. To restore ordinary delivery, set the realm
   SMTP configuration from protected `private/smtp.json`, verify a real message,
   then remove the relay service and its private file. Do not use the redacted
   password returned by the Keycloak admin API for restoration.
4. The realm renderer creates `farmerplus-pwa`, `farmerplus-learning`, and a
   service-account `farmerplus-provisioner`. The latter receives only realm user
   query/view/manage roles needed for reconciliation and logout. Keep its secret
   backend-only. Broker configuration uses a separate operator-only client with
   `manage-identity-providers`; never grant that role to the ordinary provisioner.
5. Set backend variables from `.env.example`: issuer, public PWA origin, web/client
   secrets, storage encryption key, Learning origin, and independent long random
   secrets for provisioning and introspection. For HTTPS set secure cookies to 1.
   `FARMER_KEYCLOAK_LOOPBACK=1` only permits explicit localhost/127.0.0.1 HTTP in
   non-production. Callback origin must be the PWA's cookie origin, not port 8088
   behind a different browser origin.
6. Install the reviewed Moodle candidate changes from
   `C:/e-learning/.server-edit/tenant-offline-20260914/moodle/auth/farmerplusoidc`.
   This is a staged source candidate, not evidence of the currently hosted plugin.
   Compare against deployed code before release; preserve unrelated live changes.
   Run Moodle's normal upgrade to version `2026092201` for the provision receipts.
7. In Moodle protected `config.php`, set the existing `auth_farmerplusoidc_*`
   issuer/client secret/CA file fields plus:
   - `enabled=true`, `allow_provisioning=true`
   - `tenant='farmerplus'`, `instance='farmerplus-learning'`
   - `provisioning_secret` matching backend provisioning secret
   - `introspection_url=<backend HTTPS>/oidc/resource/learning-introspect`
   - `introspection_secret` matching backend introspection secret
   - `profile_url=<issuer>/account/`, `signin_url=<PWA>/oidc/web/login`
   Keep the plugin's existing revocation scheduled task enabled.
8. Deploy Backend/PWA/contracts together. `/auth/providers` switches the PWA to
   Keycloak sign-in. Learning launch uses top-level Moodle OIDC navigation. The
   existing Keycloak browser session avoids a second password; required profile,
   linking, MFA or consent steps can still appear when policy requires them.

## Google and Apple

For a Linux/container host, `compose.yaml` and `Dockerfile` provide the separate
PostgreSQL-backed realm service and compile the Apple adapter against the same
pinned Keycloak release. Supply their required variables privately, render the
realm to `KEYCLOAK_REALM_FILE`, then use `docker compose -f identity/keycloak/compose.yaml up --build -d`
after approving that deployment target. The only mapped port binds to loopback;
configure the approved HTTPS proxy separately and set its trusted address/CIDR.
These container definitions were deployed on the authorized agritec Linux host
on 27 September 2026; Windows startup remains unsupported on this workstation.
The image build context explicitly excludes private files.

Google callback: `<issuer>/broker/google/endpoint`. Configure the Google OAuth web
client, supply its credentials to the operator environment and run
`python identity/keycloak/configure_google.py`. Then test an actual Google account
and enable `FARMER_KEYCLOAK_GOOGLE_ENABLED=1` for the PWA shortcut.

Apple callback: `<issuer>/broker/apple/endpoint`. Register the HTTPS domain/return
URL against an Apple Services ID. Keycloak has no built-in Apple provider in the
selected release. Build `apple/` with `apple/build.ps1 -KeycloakHome ... -JavaHome ...`
and install its JAR in Keycloak `providers/` before the normal Keycloak build.
The adapter adds Apple's `form_post` callback to maintained OIDC handling; it does
not implement token cryptography or accept unsigned Apple profile fields. Users
with missing names complete the realm profile step once.

Supply Apple Team ID, Key ID, Services ID and a protected `.p8` file path to the
operator environment. Run `python identity/keycloak/rotate_apple.py` daily through
your deployment scheduler and alert on failure. It creates a seven-day ES256 Apple
client-secret JWT and updates only the Apple broker. Nothing secret is printed.
Test real Apple sign-in, relay-email and existing-account linking before enabling
`FARMER_KEYCLOAK_APPLE_ENABLED=1`. Compilation/local fixtures cannot prove Apple's
domain approval or real social-login completion.

## Operations and boundaries

`GET /learning/provisioning` is owner-scoped. Monitor pending age, retries and the
worker's `last_reconcile_error` in service health/observability. Local account
sign-out invalidates backend sessions, queues Keycloak logout and redirects to
the realm logout page. Signed Keycloak backchannel logout is verified with realm
JWKS and replay protection; Moodle separately revalidates online access. A
temporary identity outage fails online access closed while retaining saved data.

Manage credentials/suspension in Keycloak. Realm admins and backend business
admins are different roles: no Keycloak user automatically becomes a backend
administrator. Assign an existing verified backend owner through the protected
administration bootstrap process. Do not grant it through editable user claims.

PWA offline records, queues, settings and Learning downloads remain keyed by
owner/tenant/instance. A new realm account does not unlock an older identity's
cached data. Keycloak passwords are never copied into the PWA offline password
vault. PWA Settings now enrolls a separate purpose-bound device passphrase after
fresh verified online proof. It unlocks saved data during transport/502/503/504
outages, while explicit 401/403 locks the workspace and invalidates its verifier.
It does not encrypt browser storage or detect remote suspension while offline.
The preserved Android
reference is not migrated to Keycloak password grants: its old credential routes
are deliberately disabled in this mode, and a native PKCE client/verified offline
unlock rollout is a separate consumer release.

Before public activation, verify real email/Google/Apple registration, duplicate
callbacks, profile updates, outage recovery, Moodle provisioning and activity
launch, entitlement denial, two-account isolation, logout/reset/suspension and
wallet-provider trust. Wallet integration still needs their client/broker
requirements, accepted issuer/audience, subject mapping and authorized account
linking flow. Separate realms require explicit trust; matching emails are not proof.

## Hosted deployment: 27 September 2026

Live PWA: https://app.agritec.earth. Issuer:
https://auth.agritec.earth/realms/farmerplus. Moodle: https://learn.agritec.earth.
See `C:/Farmer Integration/docs/keycloak-live-rollout-2026-09-27.md` for the
coordinated release evidence, Google client metadata and remaining acceptance.

Deployment directory: `/opt/farmerplus-keycloak`, root-only. Identity uses
`compose.yaml` plus `compose.agritec.yaml`; PWA/backend uses
`compose.application.yaml`. Both are in one Compose project; warnings about the
other file's services are expected. **Do not use `--remove-orphans`** with either
partial file set. To operate the entire deployment, supply all three files.

`private/application.env`, `.env`, `private/google.json` and the Moodledata
configuration contain secrets. Keep them out of logs, source, PWA assets and
support bundles. The downloaded Google credential is stored in the ignored local
`.local-development/keycloak-tools/google-oauth-client.json` for operator recovery.
Google login is enabled after a real Google authorization/callback succeeded;
Google's consent publishing status remains Testing pending approved public policy
URLs. Apple remains disabled.

Hydra and its replaced application/TLS containers were removed after the real
Keycloak/Moodle acceptance passed. The old issuer now returns HTTP 410. Legacy
volumes and a validated private dump/configuration archive remain under
`backups/hydra-retirement-20260927T073946Z`; restoring an issuer requires deliberate
operator action and coordinated consumer configuration, never a redirect.

`sh /opt/farmerplus-keycloak/backup.sh` validates Keycloak and application pg_dump
archives and saves private configuration. Cron runs daily at 02:15 server time.
Off-host storage, retention and a full restore rehearsal are still required.
The bootstrap operator credential is private in `.env`; permanent named operator
and recovery access must be handed over before broad production use.

After a release, copy `tests/keycloak_hosted_acceptance.py` into the backend and
run it there with explicit operator authorization. It uses one synthetic account,
prints no credentials, checks real SSO/provisioning/logout and temporarily
suspends only that synthetic account, restoring it in `finally`. It does not
verify inbox delivery, Apple approval or wallet trust. Its persistent credential
file is `/app/data/keycloak-acceptance.json` (0600).

Callback query logging is disabled in the backend, gateway and shared app/auth/
Learning proxy configuration. Moodle Apache uses query-free path logs; the
modified vhost is both in its build source and mounted from the host Compose
configuration on recreation. Backups of these changes are in
`backups/query-free-logs`. Existing logs were retained.
