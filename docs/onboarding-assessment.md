# Onboarding assessment

Development assessment, 2026-11-06. No production service changes or real-user account changes were made.

| Step | Result |
| --- | --- |
| Email/password validation | Email trimmed, password whitespace preserved, matching confirmation and minimum eight characters required for signup. Existing-user sign-in retains legacy password compatibility. |
| Username validation | Format, reserved names and normalization enforced locally and on the backend. Public availability RPC returns a boolean only; database uniqueness remains authoritative. |
| Concurrent username claims | Duplicate account initialization rolls back atomically. Mobile rechecks availability after masked Auth failures without assuming every server fault is a duplicate. |
| Error notifications | App-owned messages cover incorrect credentials, unconfirmed email, unavailable usernames, weak passwords, network failures, throttling and temporarily unavailable email delivery. Unknown backend errors use a safe action-specific fallback. Raw SQL/SMTP/HTTP messages are suppressed on the account screen. |
| Confirmation required | Live HTTP sign-in rejects a synthetic unconfirmed account. Email confirmation remains enabled. |
| Resume incomplete signup | Resend is available on the sign-in page after reopening, using the entered email and no password. It does not depend on state left by the original signup. Requests use neutral account-existence wording. |
| Confirmation return URL | Development returns to the current mobile sandbox's onboarding screen. The user then signs in; no automatic confirmation callback session is claimed. |
| Account initialization | Synthetic signup trigger test creates profile, preferences and a free 500,000,000-byte account. Metadata cannot assign a paid plan or allowance. |
| Confirmed sign-in/session | Live HTTP checks passed for sign-in, owner-only profile access, storage defaults, refresh and logout. Confirmation was set through development SQL for this test, bypassing email delivery. The synthetic user was deleted afterward. |
| Session navigation | Code review: startup waits for session restoration, signed-out users reach onboarding, successful sessions navigate Home, protected routes require a session. Physical-device UI execution remains unverified. |
| Basic pane | Already removed in the current mobile branch. Account creation no longer presents plan selection. |

## Remaining release blockers

- Custom SMTP has no host, sender or credentials configured in development. A real signup → inbox → confirmation → sign-in/resend test cannot pass acceptance until a verified sender/provider is configured under Supabase → Authentication → custom SMTP. No real-user confirmation emails were sent during this assessment.
- Forgotten-password recovery has no mobile workflow. A confirmed user who forgot their password cannot complete self-service recovery in this version.
- The mobile `backend.ts` currently contains a direct development connection. Published staging/production builds need environment-specific connection configuration before release; development must continue to use development. This assessment did not change production credentials or connect development to production.
- Check each environment's hosted Site URL before publishing, because shared config intentionally omits this environment-specific value.

## Validation

Backend type checking and seven local tests passed; optional database runners were skipped locally. All three SQL suites were executed against managed development with rollback, including anonymous availability checks and profile-access denial. Mobile type checking, targeted lint and 47 automated tests passed. The frontend changes and deployed RPC are compatible. No passwords or session tokens were persisted in repository files.
