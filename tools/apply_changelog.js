const fs = require('fs');
const p = 'CHANGELOG.md';
let c = fs.readFileSync(p, 'utf8');
if (c.includes('Multi-tank application support for dual/quad tank sprayers')) {
  console.log('SKIP');
  process.exit(0);
}
const insert = '### Added\n- Multi-tank application support for dual/quad tank sprayers\n\n';
c = c.replace('## [Unreleased]', insert + '## [Unreleased]');
fs.writeFileSync(p, c);
console.log('OK');