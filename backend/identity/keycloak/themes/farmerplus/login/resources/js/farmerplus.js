// Progressive feedback only. Keycloak owns submission, CSRF, credentials and validation.
document.addEventListener('DOMContentLoaded', () => {
  const draftKey = 'farmerplus-registration-draft';
  if (document.body?.dataset.pageId === 'login-login-verify-email' ||
      document.querySelector('#kc-verify-email-form, #kc-verify-email-code-form')) {
    try { sessionStorage.removeItem(draftKey); } catch (_) {}
  }
  const form = document.querySelector('form');
  if (!form) return;
  if (form.id === 'kc-verify-email-code-form' && form.dataset.preview === 'true') {
    const original = document.getElementById('verification-code');
    const group = document.createElement('div');
    group.className = 'fp-code-digits';
    group.setAttribute('aria-label', 'Verification temporarily disabled');
    for (let i = 0; i < 6; i++) {
      const digit = document.createElement('input');
      digit.type = 'text'; digit.disabled = true; digit.placeholder = '–';
      group.append(digit);
    }
    original.parentElement.replaceWith(group);
    document.getElementById('fp-code-help').textContent = 'Please wait two seconds…';
    form.querySelectorAll('button').forEach(button => { button.hidden = true; });
    setTimeout(() => { HTMLFormElement.prototype.submit.call(form); }, 2000);
    return;
  }
  const code = document.getElementById('verification-code');
  if (code && form.id === 'kc-verify-email-code-form') {
    const group = document.createElement('div');
    group.className = 'fp-code-digits';
    group.setAttribute('role', 'group');
    group.setAttribute('aria-label', 'Six-digit verification code');
    const digits = Array.from({length: 6}, (_, index) => {
      const input = document.createElement('input');
      input.type = 'text'; input.inputMode = 'numeric'; input.maxLength = 6;
      input.pattern = '[0-9]'; input.required = true;
      input.autocomplete = index === 0 ? 'one-time-code' : 'off';
      input.id = 'fp-code-digit-' + (index + 1);
      input.setAttribute('aria-label', 'Digit ' + (index + 1) + ' of 6');
      input.setAttribute('aria-describedby', 'fp-code-help');
      group.append(input);
      return input;
    });
    const sync = () => { code.value = digits.map(input => input.value).join(''); };
    const fill = (text, index) => {
      const numbers = text.replace(/\D/g, '').slice(0, 6);
      if (!numbers) { digits[index].value = ''; sync(); return; }
      const start = numbers.length === 6 ? 0 : index;
      [...numbers].slice(0, 6 - start).forEach((number, offset) => {
        digits[start + offset].value = number;
      });
      sync(); digits[Math.min(start + numbers.length, 5)].focus();
    };
    digits.forEach((input, index) => {
      input.addEventListener('focus', () => input.select());
      input.addEventListener('input', () => fill(input.value, index));
      input.addEventListener('paste', event => {
        event.preventDefault(); fill(event.clipboardData.getData('text'), index);
      });
      input.addEventListener('keydown', event => {
        if (event.key === 'Backspace' && !input.value && index > 0) {
          event.preventDefault(); digits[index - 1].value = ''; sync(); digits[index - 1].focus();
        } else if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
          event.preventDefault(); digits[Math.max(0, Math.min(5, index + (event.key === 'ArrowLeft' ? -1 : 1)))].focus();
        }
      });
    });
    const wrapper = code.parentElement;
    wrapper.after(group);
    wrapper.hidden = true;
    code.type = 'hidden'; code.required = false;
    document.querySelector('label[for="verification-code"]')?.setAttribute('for', digits[0].id);
    if (code.value) fill(code.value, 0);
    else digits[0].focus();
    form.addEventListener('submit', sync);
    addEventListener('pageshow', sync);
  }
  const registration = form.id === 'kc-register-form';
  if (registration) {
    try {
      const draft = JSON.parse(sessionStorage.getItem(draftKey) || 'null');
      if (draft && Date.now() - draft.time < 30 * 60 * 1000) {
        for (const name of ['email', 'firstName', 'lastName']) {
          const input = form.elements.namedItem(name);
          if (input && !input.value && typeof draft[name] === 'string') input.value = draft[name];
        }
      } else sessionStorage.removeItem(draftKey);
    } catch (_) { /* Storage is optional; server validation keeps current values. */ }
    for (const id of ['password', 'password-confirm']) {
      const input = document.getElementById(id);
      if (input) input.setAttribute('aria-describedby', [input.getAttribute('aria-describedby'), 'fp-password-help'].filter(Boolean).join(' '));
    }
  }
  const status = document.createElement('span');
  status.className = 'fp-submit-status';
  status.setAttribute('role', 'status');
  form.append(status);
  form.addEventListener('submit', () => {
    if (registration) {
      const draft = { time: Date.now() };
      for (const name of ['email', 'firstName', 'lastName']) draft[name] = form.elements.namedItem(name)?.value || '';
      try { sessionStorage.setItem(draftKey, JSON.stringify(draft)); } catch (_) {}
    }
    form.setAttribute('aria-busy', 'true');
    status.textContent = registration ? 'Creating your account…' : 'Please wait…';
    // Keep the clicked submit control in the request; disabling it synchronously
    // can remove Keycloak's required action name from the submitted form.
    setTimeout(() => form.querySelectorAll('[type=submit]').forEach(b => b.disabled = true), 0);
  });
  addEventListener('pageshow', () => {
    form.removeAttribute('aria-busy'); status.textContent = '';
    form.querySelectorAll('[type=submit]').forEach(b => b.disabled = false);
  });
});
