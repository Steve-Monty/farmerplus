# FarmerPlus sign-in theme

Parent: Keycloak **26.7.4**, `keycloak.v2`. `login/template.ftl` and
`login/register.ftl` are adapted from that release's templates (Apache-2.0,
https://github.com/keycloak/keycloak/tree/26.7.4/themes). Keep their native form
actions, hidden session fields, password controls, validation macros and session
scripts when upgrading. Review upstream changes on every Keycloak version bump.

Brand assets are unmodified copies from `C:/Farmer PWA/assets/branding`:

- `wordmark.png`: tightly cropped horizontal wordmark, used in the header.
- `farm-wallpaper.png`: the app's existing farm backdrop.
- `fp-original.png`: square app mark, used only as the favicon.

Do not substitute the square mark for the wordmark or recreate either logo.
The CSS inherits the app's purple action colour, pale panels and farm imagery.

Registration uses Keycloak's REQUIRED Password Validation action with
`always_set_password_on_register_form=true`. Without this, 26.7 defers password
setup until after verification. Email verification remains mandatory. This
compatibility setting is deprecated upstream: test its replacement before moving
off 26.7.4. Password requirements remain server-enforced.

JavaScript adds loading feedback and a per-tab, 30-minute non-password draft for
expiry recovery. It never handles credentials or replaces native form submission.
The realm enforces an eight-character minimum. Passwords are never saved in the draft. Verification clears it; abandoned drafts
expire on the next registration visit or disappear when the tab closes.

The Learning journey adds SMTP/reset/provider recovery copy. Reset confirmation
remains deliberately non-enumerating, including when SMTP fails. Verification
draft cleanup recognizes Keycloak 26.7.4's `login-login-verify-email` page ID;
`node --test tests/keycloak_theme.test.cjs` tests expiry and exclusion of passwords.

New installations use realm.py. Existing realms use upgrade_registration.py
after the theme image is installed; never overwrite a live realm by importing a
fresh realm export. The script is read-only unless --apply is supplied and takes
a narrow pre-change snapshot for rollback. A failed partial update can be rerun;
restore snapshot fields/config/profile if rollback is required.
