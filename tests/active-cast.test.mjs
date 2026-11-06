import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import test from 'node:test';
import ts from 'typescript';

function load(name, fetcher, extra = {}) {
  let handler;
  const env = { SUPABASE_URL: 'https://backend.example.invalid', SUPABASE_ANON_KEY: 'test-public', SUPABASE_SERVICE_ROLE_KEY: 'test-service', CAST_VIEWER_ORIGINS: 'https://viewer.example.invalid', CAST_OWNER_ORIGINS: 'https://owner.example.invalid', ...extra };
  const source = ts.transpileModule(readFileSync(`supabase/functions/${name}/index.ts`, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText.replace('export {};', '');
  vm.runInNewContext(source, { Deno: { env: { get: (key) => env[key] }, serve: (fn) => { handler = fn; } }, fetch: fetcher, Request, Response, URL, TextEncoder, TextDecoder, Uint8Array, AbortSignal, crypto: webcrypto });
  return handler;
}
function req(body, origin, authorization) {
  return new Request('https://edge.example.invalid/', { method: 'POST', headers: { 'Content-Type': 'application/json', ...(origin ? { origin } : {}), ...(authorization ? { authorization } : {}) }, body: JSON.stringify(body) });
}
test('viewer hashes a capability token and never forwards the raw token or returns a storage URL', async () => {
  const token = 'a'.repeat(64);
  let called = 0;
  const handler = load('cast-viewer', async (url, options) => {
    called++;
    assert.equal(url, 'https://backend.example.invalid/rest/v1/rpc/cast_viewer');
    const body = JSON.parse(options.body);
    assert.equal(body.p_token_hash, Buffer.from(await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(token))).toString('hex'));
    assert.equal(options.body.includes(token), false);
    assert.equal(body.p_action, 'heartbeat');
    return Response.json({ video_state: 'ingest_transcode_distribution_not_configured' });
  });
  const result = await handler(req({ token, action: 'heartbeat' }, 'https://viewer.example.invalid'));
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.equal((await result.json()).video_state, 'ingest_transcode_distribution_not_configured');
  assert.equal(called, 1);
});
test('viewer rejects malformed tokens, forbidden origins, query tokens and large streamed bodies before database access', async () => {
  const handler = load('cast-viewer', () => { throw new Error('must not fetch'); });
  assert.equal((await handler(req({ token: 'bad', action: 'location' }))).status, 400);
  assert.equal((await handler(req({}, 'https://untrusted.example.invalid'))).status, 403);
  assert.equal((await handler(new Request('https://edge.example.invalid/?token=secret'))).status, 400);
  assert.equal((await handler(req({ token: 'a'.repeat(64), action: 'message', input: { body: 'x'.repeat(9000) } }))).status, 413);
});
test('viewer returns access denial and suppresses database error details', async () => {
  const handler = load('cast-viewer', async () => Response.json({ message: 'scope_denied', details: 'do not expose' }, { status: 403 }));
  const result = await handler(req({ token: 'a'.repeat(64), action: 'location' }));
  assert.equal(result.status, 403);
  assert.deepEqual(await result.json(), { error: 'access_denied' });
});
test('owner requires verified Auth session before invoking owner RPC with the original user token', async () => {
  let calls = 0;
  const handler = load('active-cast', async (url, options) => {
    assert.equal(options.headers.Authorization, 'Bearer owner-jwt');
    assert.equal(options.headers.apikey, 'test-public');
    calls++;
    return url.endsWith('/auth/v1/user') ? Response.json({ id: 'owner' }) : Response.json({ error: 'revision_conflict', current: { revision: 4 } });
  });
  assert.equal((await handler(req({ action: 'presets_get' }))).status, 401);
  assert.equal(calls, 0);
  const result = await handler(req({ action: 'presets_save', input: {} }, undefined, 'Bearer owner-jwt'));
  assert.equal(result.status, 409);
  assert.equal(calls, 2);
});
test('invalid Auth response never reaches the database', async () => {
  let calls = 0;
  const handler = load('active-cast', async () => { calls++; return Response.json({}, { status: 401 }); });
  assert.equal((await handler(req({}, undefined, 'Bearer invalid'))).status, 401);
  assert.equal(calls, 1);
});
test('database authorization, ordering and recovery suite', { skip: !process.env.CAST_TEST_DATABASE_URL }, () => {
  const result = spawnSync('psql', ['-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', process.env.CAST_TEST_DATABASE_URL, '-f', 'tests/active_cast_security.sql'], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
});
