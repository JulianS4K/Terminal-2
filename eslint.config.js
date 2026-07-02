// ESLint flat config — the structural half of coding-recommendation #4.
//
// Bans raw HTML-injection sinks (`innerHTML` / `outerHTML` assignment,
// `insertAdjacentHTML`) so untrusted strings can't reach the DOM unescaped.
// The ONE sanctioned exception is static/lib/s4k.js's `setTrustedHTML` sink,
// which carries an inline eslint-disable — every other site must build nodes
// via S4K.el / S4K.setText or interpolate through S4K.esc.
//
// Enforcement is a RATCHET (mirrors the mypy foothold in tests.yml): the eslint
// CI job runs this as a BLOCKING gate over the clean shared-lib surface
// (static/lib/**), and as an advisory pass over the rest of static/** (which
// still carries ~31 legacy innerHTML sites). Migrate a surface onto S4K, then
// move it into the blocking glob. Never widen the allowance.
'use strict';

const noRawHtmlSinks = {
  rules: {
    'no-restricted-properties': ['error',
      { object: undefined, property: 'innerHTML',
        message: 'Raw innerHTML is banned (XSS). Use S4K.setText / S4K.el, or S4K.setTrustedHTML with S4K.esc-escaped markup.' },
      { object: undefined, property: 'outerHTML',
        message: 'Raw outerHTML is banned (XSS). Build nodes via S4K.el instead.' },
    ],
    'no-restricted-syntax': ['error',
      { selector: "CallExpression[callee.property.name='insertAdjacentHTML']",
        message: 'insertAdjacentHTML is banned (XSS). Use S4K.el + appendChild, or S4K.setTrustedHTML with escaped markup.' },
    ],
  },
};

module.exports = [
  {
    files: ['static/**/*.js', 'd2_dashboard/static/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'script',
      globals: { window: 'readonly', document: 'readonly', S4K: 'readonly', TermRender: 'readonly' },
    },
    ...noRawHtmlSinks,
  },
];
