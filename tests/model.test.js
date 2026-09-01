const fs = require('fs');
const vm = require('vm');
const assert = require('assert');

const source = fs.readFileSync('Model.js', 'utf8');
const context = {};
vm.createContext(context);
vm.runInContext(source, context);

const uuidA = '11111111-1111-4111-8111-111111111111';
const uuidB = '22222222-2222-4222-8222-222222222222';

assert.deepStrictEqual(
  Array.from(context.splitEscapedColon('Work\\: VPN:' + uuidA + ':wireguard:wg0')),
  ['Work: VPN', uuidA, 'wireguard', 'wg0']
);

const profiles = context.parseProfiles([
  'Home:' + uuidA + ':wireguard:',
  'Work\\: VPN:' + uuidB + ':wireguard:wg-work',
  'WiFi:33333333-3333-4333-8333-333333333333:802-11-wireless:wlan0'
].join('\n'));

assert.strictEqual(profiles.length, 2);
assert.strictEqual(profiles[0].uuid, uuidB);
assert.strictEqual(profiles[0].active, true);
assert.strictEqual(profiles[0].name, 'Work: VPN');
assert.strictEqual(profiles[1].active, false);

const fresh = context.findNewProfile([uuidA], profiles);
assert.strictEqual(fresh.uuid, uuidB);
assert.strictEqual(context.findNewProfile([], profiles), null);
assert.strictEqual(context.isUuid(uuidA), true);
assert.strictEqual(context.isUuid('not-a-uuid'), false);
assert.strictEqual(context.cleanError('line one\nline two\n', 'fallback'), 'line two');

console.log('Model tests passed');
