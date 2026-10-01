'use strict';
document.getElementById('local-signout')?.addEventListener('click', async event => {
  event.target.disabled = true;
  const csrf = document.cookie.split('; ').find(v => v.startsWith('fp_admin_csrf='))?.split('=')[1] || '';
  try {
    const response = await fetch('/admin/logout', {method:'POST', credentials:'same-origin', headers:{'X-CSRF-Token':csrf}});
    if (!response.ok && response.status !== 401) throw Error('Sign out could not finish. Try again.');
    location.assign('/admin/login');
  } catch (error) { document.getElementById('login-error').textContent = error.message; event.target.disabled = false; }
});
