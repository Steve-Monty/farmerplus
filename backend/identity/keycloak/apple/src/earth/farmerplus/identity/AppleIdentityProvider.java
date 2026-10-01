package earth.farmerplus.identity;

import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.FormParam;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.core.UriBuilder;
import org.keycloak.broker.oidc.OIDCIdentityProvider;
import org.keycloak.broker.oidc.OIDCIdentityProviderConfig;
import org.keycloak.broker.provider.AuthenticationRequest;
import org.keycloak.events.EventBuilder;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;

/** Apple posts its authorization response. All state, nonce, token and signature
 * verification stays in Keycloak's maintained OIDC implementation. Unsigned
 * first-login names from Apple's `user` form field are deliberately ignored;
 * the realm's required profile step collects missing names once. */
public final class AppleIdentityProvider extends OIDCIdentityProvider {
    public AppleIdentityProvider(KeycloakSession session, OIDCIdentityProviderConfig config) {
        super(session, config);
    }

    @Override
    protected UriBuilder createAuthorizationUrl(AuthenticationRequest request) {
        return super.createAuthorizationUrl(request).replaceQueryParam("response_mode", "form_post");
    }

    @Override
    public Object callback(RealmModel realm, AuthenticationCallback callback, EventBuilder event) {
        return new AppleEndpoint(callback, realm, event, this);
    }

    public static final class AppleEndpoint extends OIDCEndpoint {
        public AppleEndpoint(AuthenticationCallback callback, RealmModel realm, EventBuilder event,
                             AppleIdentityProvider provider) {
            super(callback, realm, event, provider);
        }

        @POST
        @Consumes(MediaType.APPLICATION_FORM_URLENCODED)
        public Response postedResponse(@FormParam("state") String state,
                                       @FormParam("code") String code,
                                       @FormParam("error") String error,
                                       @FormParam("error_description") String description) {
            return super.authResponse(state, code, error, description);
        }
    }
}
