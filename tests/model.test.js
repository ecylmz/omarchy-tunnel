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

const parsed = context.parseProfiles([
  'Home:' + uuidA + ':wireguard:',
  'Work\\: VPN:' + uuidB + ':wireguard:wg-work',
  'WiFi:33333333-3333-4333-8333-333333333333:802-11-wireless:wlan0'
].join('\n'));
assert.strictEqual(parsed.ok, true);
const profiles = parsed.profiles;

assert.strictEqual(profiles.length, 2);
assert.strictEqual(profiles[0].uuid, uuidB);
assert.strictEqual(profiles[0].active, true);
assert.strictEqual(profiles[0].name, 'Work: VPN');
assert.strictEqual(profiles[1].active, false);

assert.strictEqual(context.isUuid(uuidA), true);
assert.strictEqual(context.isUuid('not-a-uuid'), false);
assert.strictEqual(context.parseImportResult('OK:' + uuidA + '\n'), uuidA);
assert.strictEqual(context.parseImportResult('prefix OK:' + uuidA), '');
assert.strictEqual(context.parseImportResult('OK:' + uuidA + '\nOK:' + uuidB), '');
assert.strictEqual(context.cleanError('line one\nline two\n', 'fallback'), 'line two');

const invalidFields = context.parseProfiles([
  'x'.repeat(129) + ':' + uuidA + ':wireguard:wg0',
  'bad-device:' + uuidA + ':wireguard:this-device-name-is-too-long',
  'control\tname:' + uuidA + ':wireguard:wg0'
].join('\n'));
assert.strictEqual(invalidFields.ok, true);
assert.strictEqual(invalidFields.profiles.length, 0);

const oversized = context.parseProfiles('x'.repeat(65537));
assert.strictEqual(oversized.ok, false);
assert.strictEqual(oversized.profiles.length, 0);

const tooMany = context.parseProfiles(Array(258).fill('wifi:' + uuidA + ':wifi:wlan0').join('\n'));
assert.strictEqual(tooMany.ok, false);

assert.strictEqual(context.boundedDisplayText('<b>plain</b>', 40), '<b>plain</b>');
assert.strictEqual(context.boundedDisplayText('a'.repeat(20), 10), 'aaaaaaa...');

console.log('Model tests passed');
