# Email verification inside the app

The FarmerPlus `VERIFY_EMAIL` required-action provider replaces verification links
with a six-digit code entered in the same browser that registered or signed in.
After a correct code, Keycloak completes its existing authorization-code flow.
The backend still checks state, PKCE, nonce, issuer and account status before
creating the app session. No passwordless cross-browser session is created.

Codes expire after ten minutes and allow five attempts. A shared, atomic
per-realm/user cooldown limits sends to one per minute, including across browser
sessions. A fresh code replaces the previous challenge. Only a salted hash, email,
expiry and attempt count are stored in the authentication session. Codes and mail
contents are not logged. Keycloak's normal authentication-session expiry also
applies. If another flow verifies an account during registration, the original
session still restarts, preserving Keycloak's existing protection.

The realm must select `farmerplus` as both login and email theme. This provider
uses Keycloak 26.7.4's required-action SPI, so upgrades require compilation and real
registration/reset tests. It is packaged with the existing provider jar; its
factory order selects it for `VERIFY_EMAIL`. Existing email action links remain
handled by Keycloak's built-in action-token handler; new verification challenges
use the code screen. Verified Google accounts skip this action as before.

For rollback, restore the prior identity image and the prior realm email theme.
Accounts already verified stay verified. Pending users can request a fresh
verification challenge after reopening sign-in. Keep the original password,
registration, reset and error templates: those routes are still required.

The backend callback rotates only the central/app sessions presented by the
current browser after successful authentication. Other devices and owner-scoped
saved records remain untouched.
