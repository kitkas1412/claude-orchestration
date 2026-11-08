#!/usr/bin/env node
'use strict';

// npm runs this file through a symlink, but Node resolves __dirname to the real package path.
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const installer = path.join(__dirname, '..', 'install.sh');
const result = spawnSync('bash', [installer, ...process.argv.slice(2)], { stdio: 'inherit' });

if (result.error) {
  console.error(`Could not run the installer: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
