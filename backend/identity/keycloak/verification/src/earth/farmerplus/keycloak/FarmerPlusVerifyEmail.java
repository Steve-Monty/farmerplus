package earth.farmerplus.keycloak;

import java.util.Map;
import java.util.HashMap;
import jakarta.ws.rs.core.Response;
import org.keycloak.authentication.AuthenticationProcessor;
import org.keycloak.Config;
import org.keycloak.authentication.InitiatedActionSupport;
import org.keycloak.authentication.RequiredActionContext;
import org.keycloak.authentication.RequiredActionFactory;
import org.keycloak.authentication.RequiredActionProvider;
import org.keycloak.email.EmailException;
import org.keycloak.email.EmailTemplateProvider;
import org.keycloak.events.Details;
import org.keycloak.events.EventType;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.models.UserModel;
import org.keycloak.sessions.AuthenticationSessionModel;
import org.keycloak.services.Urls;
import org.keycloak.services.managers.AuthenticationManager;

/** Keep verification in the original browser's authenticated registration flow. */
public final class FarmerPlusVerifyEmail implements RequiredActionProvider, RequiredActionFactory {
    private static final String PREFIX = "fp.email.code.";
    private static final int COOLDOWN_SECONDS = 60;
    private static final String ACTION = UserModel.RequiredAction.VERIFY_EMAIL.name();
    private static final String PREVIEW = "farmerplus.email-verification-preview";
    private boolean preview(RequiredActionContext context) {
        return "true".equals(context.getRealm().getAttribute(PREVIEW));
    }
    @Override public String getId() { return ACTION; }
    @Override public int order() { return 100; }
    @Override public String getDisplayText() { return "FarmerPlus email verification code"; }
    @Override public RequiredActionProvider create(KeycloakSession session) { return this; }
    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}
    @Override public InitiatedActionSupport initiatedActionSupport() { return InitiatedActionSupport.SUPPORTED; }

    @Override public void evaluateTriggers(RequiredActionContext context) {
        UserModel user = context.getUser();
        if (!preview(context) && "true".equals(user.getFirstAttribute(PREVIEW))) {
            user.setEmailVerified(false);
            user.removeAttribute(PREVIEW);
        }
        if (context.getRealm().isVerifyEmail() && !user.isEmailVerified() &&
                user.getEmail() != null && !user.getEmail().isBlank() &&
                user.getRequiredActionsStream().noneMatch(UserModel.RequiredAction.UPDATE_EMAIL.name()::equals)) {
            user.addRequiredAction(ACTION);
        }
    }

    @Override public void requiredActionChallenge(RequiredActionContext context) {
        if (alreadyVerified(context)) return;
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        if (preview(context)) {
            auth.setAuthNote(PREFIX + "previewStart", Long.toString(System.currentTimeMillis()));
            auth.setAuthNote(PREFIX + "email", context.getUser().getEmail());
            show(context, null); return;
        }
        if (auth.getAuthNote(PREFIX + "hash") == null) { send(context); return; }
        show(context, null);
    }

    @Override public void processAction(RequiredActionContext context) {
        if (alreadyVerified(context)) return;
        if (preview(context)) {
            AuthenticationSessionModel previewAuth = context.getAuthenticationSession();
            long started = number(previewAuth.getAuthNote(PREFIX + "previewStart"));
            if (started <= 0 || System.currentTimeMillis() - started < 2000 ||
                    !java.util.Objects.equals(context.getUser().getEmail(), previewAuth.getAuthNote(PREFIX + "email"))) {
                requiredActionChallenge(context); return;
            }
            context.getUser().setSingleAttribute(PREVIEW, "true");
            context.getUser().setEmailVerified(true);
            context.getUser().removeRequiredAction(ACTION);
            previewAuth.removeRequiredAction(ACTION);
            clear(previewAuth);
            context.success(); return;
        }
        String action = context.getHttpRequest().getDecodedFormParameters().getFirst("fp_action");
        if ("resend".equals(action)) { send(context); return; }
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        long now = System.currentTimeMillis() / 1000;
        long expiry = number(auth.getAuthNote(PREFIX + "expires"));
        int attempts = (int) number(auth.getAuthNote(PREFIX + "attempts"));
        String currentEmail = context.getUser().getEmail();
        if (now >= expiry || !java.util.Objects.equals(currentEmail, auth.getAuthNote(PREFIX + "email"))) {
            show(context, "fpCodeExpired"); return;
        }
        if (attempts >= VerificationCode.MAX_ATTEMPTS) { show(context, "fpCodeAttempts"); return; }
        String code = context.getHttpRequest().getDecodedFormParameters().getFirst("verification_code");
        if (!VerificationCode.matches(auth.getAuthNote(PREFIX + "hash"), auth.getAuthNote(PREFIX + "salt"),
                currentEmail, code, expiry, now, attempts)) {
            auth.setAuthNote(PREFIX + "attempts", Integer.toString(attempts + 1));
            show(context, attempts + 1 >= VerificationCode.MAX_ATTEMPTS ? "fpCodeAttempts" : "fpCodeInvalid");
            return;
        }
        context.getUser().setEmailVerified(true);
        context.getUser().removeAttribute(PREVIEW);
        context.getUser().removeRequiredAction(ACTION);
        auth.removeRequiredAction(ACTION);
        clear(auth);
        context.getEvent().clone().event(EventType.VERIFY_EMAIL)
            .detail(Details.EMAIL, currentEmail).success();
        context.success();
    }

    private void send(RequiredActionContext context) {
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        String email = context.getUser().getEmail();
        if (email == null || email.isBlank()) { show(context, "fpCodeDeliveryFailed"); return; }
        String cooldownKey = PREFIX + context.getRealm().getId() + ":" + context.getUser().getId();
        if (!context.getSession().singleUseObjects().putIfAbsent(cooldownKey, COOLDOWN_SECONDS)) {
            show(context, "fpCodeCooldown"); return;
        }
        clear(auth);
        String code = VerificationCode.generate();
        String salt = VerificationCode.salt();
        try {
            context.getSession().getProvider(EmailTemplateProvider.class)
                .setAuthenticationSession(auth).setRealm(context.getRealm()).setUser(context.getUser())
                .send("fpEmailVerificationCodeSubject", "email-verification-code.ftl",
                    new HashMap<>(Map.of("verificationCode", code, "expirationMinutes", VerificationCode.LIFETIME_SECONDS / 60)));
            auth.setAuthNote(PREFIX + "hash", VerificationCode.digest(salt, email, code));
            auth.setAuthNote(PREFIX + "salt", salt);
            auth.setAuthNote(PREFIX + "email", email);
            auth.setAuthNote(PREFIX + "expires", Long.toString(System.currentTimeMillis() / 1000 + VerificationCode.LIFETIME_SECONDS));
            auth.setAuthNote(PREFIX + "attempts", "0");
            context.getEvent().clone().event(EventType.SEND_VERIFY_EMAIL).detail(Details.EMAIL, email).success();
            show(context, null);
        } catch (EmailException e) {
            // Do not log the message, code, SMTP credentials or exception content.
            context.getEvent().clone().event(EventType.SEND_VERIFY_EMAIL)
                .detail(Details.REASON, e.getCause() == null ? e.getClass().getSimpleName() : e.getCause().getClass().getSimpleName())
                .error("email_send_failed");
            show(context, "fpCodeDeliveryFailed");
        }
    }

    private void show(RequiredActionContext context, String error) {
        var form = context.form().setAttribute("verificationEmail", context.getUser().getEmail())
            .setAttribute("verificationPreview", preview(context));
        if (error != null) form.setError(error);
        context.challenge(form.createForm("verify-email-code.ftl"));
    }
    private boolean alreadyVerified(RequiredActionContext context) {
        if (!context.getUser().isEmailVerified()) return false;
        AuthenticationSessionModel auth = context.getAuthenticationSession();
        // Preserve Keycloak's protection when some OTHER flow verified the email.
        // Only entering this session's code below completes its registration.
        if ("true".equals(auth.getAuthNote(AuthenticationManager.NEW_USER_REGISTERED))) {
            var restart = Urls.realmLoginRestartPage(context.getUriInfo().getBaseUri(),
                context.getRealm().getName(), auth.getClient().getClientId(), auth.getTabId(),
                AuthenticationProcessor.getClientData(context.getSession(), auth), false);
            context.challenge(Response.status(302).location(restart).build());
        } else { context.success(); }
        return true;
    }
    private static long number(String value) {
        try { return Long.parseLong(value); } catch (RuntimeException e) { return 0; }
    }
    private static void clear(AuthenticationSessionModel auth) {
        for (String key : new String[]{"hash", "salt", "email", "expires", "attempts", "previewStart"}) auth.removeAuthNote(PREFIX + key);
    }
}
