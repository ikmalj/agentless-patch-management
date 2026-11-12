/* Auto / Light / Dark switch in the top bar. "Auto" follows the device's setting; a Light or Dark
   choice is saved in this browser (localStorage) and applied before the page paints by the small
   script in <head>. Changing it tells the dashboard to redraw (event "themechange"). */
(function () {
  'use strict';
  var root = document.documentElement;
  var buttons = Array.prototype.slice.call(document.querySelectorAll('[data-theme-choice]'));
  function current() { var t = root.getAttribute('data-theme'); return t === 'dark' || t === 'light' ? t : 'auto'; }
  function mark() {
    var c = current();
    buttons.forEach(function (b) { b.setAttribute('aria-pressed', String(b.getAttribute('data-theme-choice') === c)); });
  }
  function choose(choice) {
    if (choice === 'auto') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', choice);
    try { if (choice === 'auto') localStorage.removeItem('theme'); else localStorage.setItem('theme', choice); } catch (e) { /* not saved; still applied */ }
    mark();
    document.dispatchEvent(new Event('themechange'));
  }
  buttons.forEach(function (b) { b.addEventListener('click', function () { choose(b.getAttribute('data-theme-choice')); }); });
  mark();
})();
