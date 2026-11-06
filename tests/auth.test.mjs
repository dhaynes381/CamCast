import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

test('account initialization, username claims and attribution security', { skip: !process.env.CAST_TEST_DATABASE_URL }, () => {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', process.env.CAST_TEST_DATABASE_URL, '-f', 'tests/auth_security.sql'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});
