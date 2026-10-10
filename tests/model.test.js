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

const splitOff = context.parseNeverDefault('no\nno\n');
assert.strictEqual(splitOff.ok, true);
assert.strictEqual(splitOff.split, false);
assert.strictEqual(splitOff.v4, 'no');

const splitOn = context.parseNeverDefault('yes\nyes\n');
assert.strictEqual(splitOn.ok, true);
assert.strictEqual(splitOn.split, true);

const splitPartial = context.parseNeverDefault('yes\nno\n');
assert.strictEqual(splitPartial.ok, true);
assert.strictEqual(splitPartial.split, true);

const splitSingle = context.parseNeverDefault('yes\n');
assert.strictEqual(splitSingle.ok, true);
assert.strictEqual(splitSingle.split, true);

assert.strictEqual(context.parseNeverDefault('maybe\nno\n').ok, false);
assert.strictEqual(context.parseNeverDefault('').ok, false);
assert.strictEqual(context.parseNeverDefault('x'.repeat(65)).ok, false);

const showArgs = Array.from(context.splitShowArgs(uuidA));
assert.deepStrictEqual(showArgs, ['--get-values', 'ipv4.never-default,ipv6.never-default', 'connection', 'show', 'uuid', uuidA]);
assert.strictEqual(context.splitShowArgs('not-a-uuid'), null);

const modifyOn = Array.from(context.splitModifyArgs(uuidA, true));
assert.ok(modifyOn.includes('ipv4.never-default'));
assert.ok(modifyOn.includes('yes'));
assert.ok(modifyOn.includes(uuidA));
const modifyOff = Array.from(context.splitModifyArgs(uuidA, false));
assert.ok(modifyOff.includes('no'));
assert.strictEqual(context.splitModifyArgs('bad', true), null);
assert.strictEqual(context.splitStateText(true), 'Split');
assert.strictEqual(context.splitStateText(false), 'Full');

console.log('Model tests passed');
