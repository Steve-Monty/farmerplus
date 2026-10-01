package earth.farmerplus.keycloak;

public class VerificationCodeTest {
    private static void check(boolean value) { if (!value) throw new AssertionError(); }
    public static void main(String[] args) {
        String email="test@example.invalid", salt=VerificationCode.salt(), code=VerificationCode.generate();
        String hash=VerificationCode.digest(salt,email,code);
        check(code.matches("[0-9]{6}"));
        check(VerificationCode.matches(hash,salt,email,code,1600,1000,0));
        check(VerificationCode.matches(hash,salt,email,code,1600,1599,4));
        check(!VerificationCode.matches(hash,salt,email,code,1600,1600,0));
        check(!VerificationCode.matches(hash,salt,email,code,1600,1000,5));
        check(!VerificationCode.matches(hash,salt,"other@example.invalid",code,1600,1000,0));
        check(!VerificationCode.matches(hash,VerificationCode.salt(),email,code,1600,1000,0));
        check(!VerificationCode.matches(hash,salt,email,"abcdef",1600,1000,0));
        check(!VerificationCode.matches(hash,salt,email,null,1600,1000,0));
        check(!VerificationCode.matches(null,salt,email,code,1600,1000,0));
        System.out.println("PASS verification code expiry, attempt bound, email/session binding and malformed input");
    }
}
