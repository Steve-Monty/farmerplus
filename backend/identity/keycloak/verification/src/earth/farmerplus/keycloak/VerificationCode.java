package earth.farmerplus.keycloak;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.util.Base64;

/** Short-lived proof scoped to an authentication session and its current email. */
public final class VerificationCode {
    private static final SecureRandom RANDOM = new SecureRandom();
    public static final int LIFETIME_SECONDS = 600;
    public static final int MAX_ATTEMPTS = 5;
    public static String generate() { return String.format("%06d", RANDOM.nextInt(1_000_000)); }
    public static String salt() {
        byte[] bytes = new byte[24]; RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
    public static String digest(String salt, String email, String code) {
        try {
            byte[] bytes = MessageDigest.getInstance("SHA-256")
                .digest((salt + "\0" + email + "\0" + code).getBytes(StandardCharsets.UTF_8));
            return Base64.getEncoder().encodeToString(bytes);
        } catch (NoSuchAlgorithmException e) { throw new IllegalStateException(e); }
    }
    public static boolean matches(String expected, String salt, String email, String code,
                                  long expiresAt, long now, int attempts) {
        if (expected == null || salt == null || email == null || code == null ||
                !code.matches("[0-9]{6}") || now >= expiresAt || attempts >= MAX_ATTEMPTS) return false;
        return MessageDigest.isEqual(expected.getBytes(StandardCharsets.US_ASCII),
            digest(salt, email, code).getBytes(StandardCharsets.US_ASCII));
    }
}
