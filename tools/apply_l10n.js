const fs = require('fs');
const p = 'translations/translation_en.xml';
let c = fs.readFileSync(p, 'utf8');
if (c.includes('sf_multi_tank_short')) {
  console.log('SKIP');
  process.exit(0);
}
const s = `    <e k="sf_multi_tank_short"             v="Multi-Tank Application" />
    <e k="sf_multi_tank_long"              v="Apply fertilizer to multiple tanks at once (front + rear)" />
    <e k="sf_desc_multiTankApplication"   v="When enabled, applying product also fills or drains secondary tanks proportionally" />
`;
c = c.replace('</elements>', s + '</elements>');
fs.writeFileSync(p, c);
console.log('OK');