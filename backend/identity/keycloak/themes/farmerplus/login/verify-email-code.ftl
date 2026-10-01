<#import "template.ftl" as layout>
<@layout.registrationLayout displayMessage=true; section>
    <#if section = "header">
        ${msg("fpVerifyEmailTitle")}
    <#elseif section = "form">
        <p class="instruction fp-code-intro"><#if verificationPreview!false>Continuing automatically. Email verification is temporarily disabled.<#else>${msg("fpVerifyEmailInstruction")}<strong>${verificationEmail!''}</strong></#if></p>
        <form id="kc-verify-email-code-form" data-preview="${(verificationPreview!false)?c}" class="${properties.kcFormClass!}" action="${url.loginAction}" method="post">
            <div class="${properties.kcFormGroupClass!}">
                <label for="verification-code" class="${properties.kcLabelClass!}">${msg("fpVerificationCode")}</label>
                <span class="${properties.kcInputClass!}">
                    <input id="verification-code" name="verification_code" type="text" inputmode="numeric"
                           autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required autofocus
                           aria-describedby="fp-code-help" />
                </span>
                <p id="fp-code-help" class="fp-password-help">${msg("fpCodeHelp")}</p>
            </div>
            <div class="${properties.kcFormGroupClass!}">
                <button type="submit" name="fp_action" value="verify" class="${properties.kcButtonClass!} ${properties.kcButtonPrimaryClass!} ${properties.kcButtonBlockClass!}">${msg("fpVerifyContinue")}</button>
            </div>
            <div class="${properties.kcFormGroupClass!}">
                <button type="submit" name="fp_action" value="resend" formnovalidate class="${properties.kcButtonClass!} ${properties.kcButtonSecondaryClass!} ${properties.kcButtonBlockClass!}">${msg("fpResendCode")}</button>
            </div>
        </form>
    </#if>
</@layout.registrationLayout>
