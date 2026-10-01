package earth.farmerplus.identity;

import org.keycloak.broker.oidc.OIDCIdentityProvider;
import org.keycloak.broker.oidc.OIDCIdentityProviderConfig;
import org.keycloak.broker.oidc.OIDCIdentityProviderFactory;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;

public final class AppleIdentityProviderFactory extends OIDCIdentityProviderFactory {
    @Override public String getId() { return "farmerplus-apple"; }
    @Override public String getName() { return "Apple (FarmerPlus)"; }
    @Override public OIDCIdentityProvider create(KeycloakSession session, IdentityProviderModel model) {
        return new AppleIdentityProvider(session, new OIDCIdentityProviderConfig(model));
    }
}
