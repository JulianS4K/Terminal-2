// D5 Fantasy surface — boot shim.
//
// Fantasy was spun off from the D0 terminal into its own hub surface (served at
// /fantasy/). It reuses the terminal's shared libs (supabase/render/app/auth)
// but NOT nav.js — so two things nav.js/the terminal shell normally handle are
// wired here instead:
//   1. LOGIN_URL — auth.js resolves the login page relative to the current page
//      by default ('login.html'), which under /fantasy/ would 404. Point it at
//      the terminal's login (the ecosystem's single, already-registered OAuth
//      redirect) so sign-in works and returns here. MUST be set before auth.js
//      runs — hence this script loads first.
//   2. The header email + sign-out control (nav.js renders it on terminal pages).
window.LOGIN_URL = '/static/terminal/login.html';

document.addEventListener('DOMContentLoaded', function () {
  var A = window.TerminalAuth;
  var host = document.getElementById('fanAuth');
  if (!A || !host) return;
  A.ready.then(function () {
    var email = A.getEmail();
    if (!email) return;
    host.innerHTML = '<span class="auth-email muted small"></span> <a href="#" class="auth-signout">sign out</a>';
    host.querySelector('.auth-email').textContent = email;
    host.querySelector('.auth-signout').addEventListener('click', function (e) {
      e.preventDefault();
      A.signOut();
    });
  });
});
