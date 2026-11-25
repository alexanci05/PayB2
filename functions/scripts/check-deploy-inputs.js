'use strict';

const { readdirSync } = require('node:fs');
const path = require('node:path');

// Firebase can publish dotenv values as configuration even if the source archive excludes the file.
const source = path.resolve(__dirname, '..');
const localConfig = readdirSync(source).some((name) =>
  name === '.env' || (name.startsWith('.env.') && !name.endsWith('.example')) ||
  name === '.runtimeconfig.json');

if (localConfig) {
  console.error('Remove local dotenv and runtime config from functions/ before deployment. Use Secret Manager for secrets.');
  process.exitCode = 1;
}
