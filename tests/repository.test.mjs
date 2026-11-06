import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import test from "node:test";

test("contains the standard Supabase backend layout", () => {
  assert.equal(existsSync("supabase/config.toml"), true);
  assert.equal(existsSync("supabase/functions/hello/index.ts"), true);
  assert.equal(existsSync("supabase/migrations/20260822000000_initial.sql"), true);
});

test("keeps hosted configuration free of project credentials", () => {
  const config = readFileSync("supabase/config.toml", "utf8");
  assert.doesNotMatch(config, /access_token|database_url|service_role/i);
});

