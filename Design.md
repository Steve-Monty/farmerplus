# FarmerPlus Design

Version 0.1.5 (4020) · 29 September 2026

## Direction

A bright, calm farm workspace: countryside imagery on Home, glass navigation, colourful dimensional app icons, and clear white reading surfaces. The existing FarmerPlus wordmark and published sign-in design are the brand reference and remain unchanged.

Use glass for navigation over imagery. Use opaque cards for forms, lists and longer reading. Farmers must be able to distinguish a locally saved record from a server-confirmed sync.

## Shared tokens

| Token | Value / rule |
|---|---|
| Page background | `#F4F8FB` |
| Main text | `#102E43` |
| Secondary text | `#566780` |
| Primary action | `#5636D1`, white text |
| Soft violet | `#EDE6FF` |
| Card | White, subtle `#E4EDF4` border and soft shadow |
| Input background | `#F9FBFF` |
| Destructive action | Deep red; always labelled |
| Typeface | Bundled Roboto, with platform fallback |
| Page title | 21px / bold; App Store headline 32px / heavy |
| Card title | 18–20px / bold |
| Body | 16px; approximately 1.35–1.5 line height |
| Metadata / badges | 12–14px; never the only indication of state |
| Card radius | 22px |
| Inputs / icon backgrounds | 14–16px |
| App icon corners | Rounded square, approximately 29% of icon width |
| Spacing | 4, 8, 12, 16, 20, 24, 32px |
| Touch targets | At least 48px for interactive controls |
| Content width | Up to 680px, centred on larger screens |

## Navigation and icons

`AppArtwork` is the single source for icons on Home, page headers and store listings. Never substitute a different store icon when opening the App Store.

- App Store: cyan-to-blue tile, white tool-shaped A.
- Learning: bright violet tile, white open book.
- My Farm: teal tile, white home and leaf.
- Inbox: coral tile, conversation bubble and handset.
- Wallet: violet tile, white wallet and yellow card.
- Settings: muted periwinkle tile and silver gear.
- Mini-apps retain recognisable animal, cooperative, stock, diary, planner, harvest and guide symbols in the same rounded, shaded treatment.

Home keeps the farmer's wallpaper and saved icon order. Icons have white labels with contrast shadows. The translucent bottom dock includes both icons and labels. High-contrast mode keeps stronger opaque backing. Home retains useful weather and sync status; the reference artwork is not a reason to remove real information.

Internal pages use one header: circular Back control when navigation can go back, app artwork, page title, and Home action. Do not add duplicate Home buttons in individual mini-app content.

## App Store

Lead with “Useful tools. Ready when you are.” Emphasise the second line in the primary violet. Follow with Free and Works offline filters, then the category field.

Each app uses a white card with its shared icon, title, short explanation, capability badges and a trailing chevron. The whole card is the target. Avoid a compressed three-line ListTile for descriptions. Details and install/remove confirmations retain their existing functionality. Never imply that online account operations or online Learning are available offline just because local app records work offline.

## Settings

Start with a short description of the page. Give each destination one full-width card with a softly tinted icon tile, a clear title, helpful status/description, and a chevron.

Order: Your profile; Account & security; Location & weather; Notifications; Data sharing; Appearance; Storage & offline; Log out. Use mint for personal/location/appearance choices, blue for security/storage, amber for notifications and violet for sharing. Separate Log out and use red consistently with its existing confirmation.

Do not replace actual location, sharing, or pending-sync status with decorative example text.

## Mini-app consistency

Compiled mini-apps use `farmTheme`, `PageFrame`, `SurfaceCard`, `AppArtwork`, standard input decoration and shared buttons. Standalone list rows inside PageFrame receive the same card surface. Existing charts, maps, forms and task-specific controls retain their semantics and workflows.

Downloaded My Animals receives the host's current colour scheme, text scale and theme through its existing context bridge. Its sandbox and signed package validation remain intact. Trusted pointer/keyboard interaction inside the frame informs the host activity monitor; routine data polling does not.

## Sign-in and inactivity

The published sign-in appearance, logo, password eye, Google mark and verification-code layout remain unchanged. A normal Keycloak form timeout already creates a fresh form; that specific timeout banner is omitted from the restarted form. Incorrect-password, verification, account and service errors remain visible. Expired backend callbacks still use the bounded fresh-state recovery flow.

Normal app inactivity is 30 minutes. Touch, pointer interaction, scrolling and keyboard input count, including interaction inside My Animals. Sync, polling, weather refresh and notifications do not count. The client locks on expiry and checks elapsed wall-clock time after browser suspension. The backend independently rejects inactive sessions; an activity request cannot revive one. Saved records, queued changes and downloads remain on the device.

Activity renews the app's browser cookies rather than forcing logout at their original twelve-hour deadline. Keycloak keeps its 30-minute idle policy and a 30-day absolute security backstop; account revocation or identity-provider security expiry can still require authentication. See the [Keycloak session documentation](https://www.keycloak.org/docs/latest/server_admin/) for the distinction between idle and maximum lifetimes.

## Location and country

On the first verified sign-in, request a fresh device position with permission. Save the accepted fix immediately in the owner-bound device database. Determine the country from bundled boundaries before queuing backend sync, so network availability is not required for country lookup. Show locally saved/sync pending until the backend acknowledges the registration pin. A failed sync must never relabel a saved position as “Location unavailable.”

Keep the capture pending until a valid fix has been saved. Retry on a subsequent verified sign-in if it was not obtained. A browser permission denial, unavailable GPS or a position outside the country polygons must remain explicit; do not invent coordinates or a country. Country boundaries are contextual, not survey-grade. Weather remains off on a fresh installation.

## Accessibility and resilience

- Preserve text scaling, keyboard navigation, focus outlines and semantic labels.
- Pair colour with text or a recognisable icon.
- Keep descriptive text flexible; allow cards to grow instead of clipping.
- Preserve reduced-motion behavior and Home's high-contrast setting.
- Show separate loading, saved-local, queued, confirmed and failed states.
- Never erase offline drafts to recover a session or redraw a screen.
- Avoid flashing extra lines during background sync.

## Implementation map

- `lib/ui.dart`: palette, typography, page frame, cards, badges, shared artwork.
- `lib/main.dart`: Home layout and labelled glass dock.
- `lib/settings.dart`: settings cards and destination descriptions.
- `lib/miniapps.dart`: App Store layout.
- `lib/session_activity.dart`: interaction-based inactivity clock.
- `lib/remote_app_ui.dart` and `web/miniapp-runtime.js`: mini-app theme and activity bridge.
- `lib/location.dart`, `lib/sign_in_location.dart`, `lib/pwa_auth.dart`: durable first-sign-in location.
- Backend `keycloak_identity.py`: server activity enforcement and rolling browser cookies.
- Backend Keycloak `template.ftl`: normal restarted-form timeout handling.

Review evidence is under `docs/evidence/app-design-20260929/`. Widget-rendered examples use fixture data. Production publication is verified separately from physical-phone GPS and real-device timing.

## Release verification

Published to https://mobile.agritec.earth/ on 29 September 2026 at 15:29 UTC, version **0.1.5+4020**. Production hashes match the tested JavaScript, mini-app runtime, service worker and version file. The authentication form, identity discovery, mobile configuration, administration and Learning endpoints returned HTTP 200. Unauthenticated activity recording returns HTTP 401. Backend and identity sources match this release, and the realm's 30-minute idle policy was read back after updating it.

Validation: 153 Flutter tests passed (one test requiring a separate local API was skipped); 58 backend authentication/OIDC tests passed; 8 browser runtime tests passed; Integration's 25 tests / 57 subtests passed. Home, App Store and Settings were rendered and inspected at phone size, including large-text checks. Backups of production databases, source, prior images and realm timeout values were retained before activation.

These checks do not substitute for a physical-phone GPS permission test or an observed 30-minute idle/resume cycle on that device.
