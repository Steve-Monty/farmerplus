# My Animals implementation

## Live status — 27 September 2026

My Animals v1 is published in the production App Store. The coordinated backend
update also deployed the matching mobile build at `https://mobile.agritec.earth`.
Administration is at `https://app.agritec.earth/admin` with its independent login.
In the mobile app, open **App Store → My Animals → Install**.

A fresh live check verified synthetic-account sign-in, catalogue availability,
the full 59,919-byte package download, SHA-256 and ECDSA verification against the
served production public key, shared farm APIs, and administrator isolation.
The served main JavaScript, mini-app runtime and trust asset match the local build.
Evidence: `C:/Farmer Backend/evidence/my-animals-live-recheck-20260927.json`.
This follow-up verified the completed release; it did not redeploy services.

The downloadable app source is in `C:/Farmer Backend/miniapps/my-animals`. The PWA
contains the reusable host, installer and bridge; animal screens and client rules
are delivered in the verified package. Backend **Management → Apps** lists the logo,
version, release date, status, size, installations and release audit.

Complete API inventory: [delivered v1 reference](../../Farmer%20Integration/docs/mini-app-api-reference.md).

## Local use

Build/start with the existing `npm run build` and `npm run dev` commands in Farmer PWA.
Open App Store, select **My Animals**, install, then open. Local backend seeds v1 once.
The logo and colours follow FarmerPlus; farm locations reuse the shared area editor.

To prepare a later package, from Farmer Backend:

```powershell
.venv/Scripts/python.exe tools/build_miniapp.py --version 2 --output .local-development/my-animals-v2.json
```

Upload that file in Backend **Apps**, validate, then publish. Existing releases are
immutable. Production signing uses `FARMER_MINIAPP_SIGNING_KEY`; the corresponding
public pin must be present in the PWA trust asset. The private key stays outside
source and browser assets. The original implementation checks below were local;
the subsequent production release is recorded above.

## Verification and limits

Backend tests cover owner isolation, command retries, conflicts, unsafe corrections,
count-preserving group moves, individual identification and release lifecycle.
Integration fixtures compare Python and JavaScript projections. PWA tests cover
durable queues, removal preserving data, sign-out response isolation and parent
location protection. Browser runtime tests cover signature rejection and sandboxing.

V1 uses a complete app snapshot and one account/app revision. A concurrent device
change pauses the pending app queue for review. Records are capped at an 8 MB
aggregate; large-history paging and automatic per-record merging are future work.
The reference documents all shipped interfaces and limits, including offline browser
storage eviction and foreground synchronization. Photos selected on this device
remain offline; photos on another device download on demand.

### Verification evidence — 27 September 2026

- `npm run build`: **passed**; the final PWA bundle and service-worker resource inventory were generated. The existing Cupertino font warning remains.
- Full Flutter suite: **147 passed, 1 skipped**, using `flutter test --no-pub --concurrency=2 --timeout=2m`. The standard run hit the existing offline password test's 30-second timeout under load; the bounded rerun passed. The skipped test requires its separate live integration server.
- Backend full regression before the final two added checks: **144 passed**. Final mini-app/API regression: **19 passed**, including the new shared-parent deletion and response-nonce tests.
- Integration `npm test`: **23 passed and 56 subtests passed**, including Python/JavaScript animal-rule equivalence.
- PWA `npm run test:web`: **7 passed**. Targeted Dart analysis: **no issues**.
- Chrome at **390 × 844** and **1366 × 900**: installed and updated the signed backend package; records and pending changes survived the update. Added 40 chickens, moved 10, verified **30 + 10 = 40**, then synced. Corrected the movement to 12, verified **28 + 12 = 40**, and confirmed the original movement remained in correction history.
- Resume testing found and fixed a fixed-length decoded-byte buffer issue. The test now pauses after 32 KB, reopens the installer, resumes from that offset and only commits the verified complete package.
- Browser reload retained the installed package, corrected history, total of 40 and the unsynced correction. The disposable QA server was stopped after verification.

Screenshots: [mobile](my-animals-mobile.png), [desktop](my-animals-desktop.png), [Backend Apps](my-animals-backend-apps.png). These show synthetic local test records.

## Isolated UI test fixture

`integration_test/miniapp_preview.dart` and Backend `tools/miniapp_preview.py` provide
a disposable loopback-only QA workspace. They are not production entry points.
Build the fixture to `build/miniapp-preview`, run its backend script and open
`http://127.0.0.1:5187/index.html`. It uses synthetic animals and shared farm areas.
