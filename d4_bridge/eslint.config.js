import firebaseRulesPlugin from '@firebase/eslint-plugin-security-rules';

export default [
  {
    ignores: ['dist/**/*', 'node_modules/**/*']
  },
  {
    files: ['firestore.rules'],
    ...firebaseRulesPlugin.configs['flat/recommended']
  }
];
