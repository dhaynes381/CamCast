/** Mobile integration contract; decimal cursor strings preserve bigint precision. */
export type UUID = string;
export type Platform = "facebook" | "tiktok" | "youtube" | "x" | "twitch";
export type Recipient = { name: string; phone: string };
export type Preset = {
  id: string; name: string; description: string; artwork: string; builtin: boolean;
  legacy_name?: boolean; socialPlatforms: Platform[]; liveView: boolean;
  sendLocation: boolean; recipients: Recipient[];
};
export type Library = { owner_id: UUID; revision: number; presets: Preset[]; favorite_ids: string[]; updated_at: string };
export type Consent = { video: boolean; location: boolean; sms: boolean; platforms: Platform[] };
type Mutation = { request_id: UUID };
type Incident = { incident_id: UUID };
export type ControlInputs = {
  presets_get: Record<string, never>;
  presets_save: Mutation & { base_revision: number; presets: Preset[]; favorite_ids: string[] };
  presets_import: Mutation & { base_revision: 0; presets: Array<Omit<Preset, "socialPlatforms" | "liveView" | "sendLocation" | "recipients"> & Partial<Preset>>; favorite_ids: string[] };
  start: Mutation & Incident & { preset_id: string; preset_revision: number; device_started_at: string; device_timezone?: string; is_test?: boolean; consent: Consent };
  end: Mutation & Incident;
  status: Incident;
  feed: Incident & { after?: string; limit?: number };
  grant: Mutation & Incident & { grant_id: UUID; recipient_phone: string; include_video: boolean; include_location: boolean; expires_at: string; token_hash: string };
  revoke: Mutation & Incident & { grant_id: UUID };
  block: Mutation & Incident & { grant_id: UUID };
  location: Mutation & Incident & { sample_id: UUID; device_recorded_at: string; latitude: number; longitude: number; accuracy_m: number; share_with_recipients: boolean };
  moderate: Mutation & Incident & { message_id: UUID; decision: "approved" | "rejected" | "removed" };
};
export type ControlRequest<A extends keyof ControlInputs = keyof ControlInputs> = A extends keyof ControlInputs ? { action: A; input: ControlInputs[A] } : never;
export type ViewerRequest = { token: string } & (
  { action: "heartbeat" | "location"; input?: Record<string, never> } |
  { action: "message"; input: { message_id: UUID; body: string } }
);
export type MessageEvent = {
  cursor: string; message_id: UUID; kind: "approved" | "removed"; occurred_at: string;
  body: string | null; sender_label: "Guest"; verified_user_id: UUID | null;
};
export type Feed = { events: MessageEvent[]; next_cursor: string; head_cursor: string };
export type LocationResult = { state: "no_shared_fix" } | {
  state: "approximate_fix"; latitude: number; longitude: number; accuracy_m: number;
  device_recorded_at: string; received_at: string; age_seconds: number; stale: boolean;
};
export type CastJob = {
  id: UUID; incident_id: UUID; owner_id: UUID; kind: "sms" | "broadcast_start" | "broadcast_end";
  target: string; payload: Record<string, unknown>;
  state: "unavailable" | "queued" | "working" | "ambiguous" | "retry" | "confirmed" | "failed";
  error_code: string | null; attempts: number; next_attempt_at: string | null;
  provider_id: string | null; provider_confirmed_at: string | null;
};
