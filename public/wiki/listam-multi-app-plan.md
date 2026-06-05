# Listam Multi-App Architecture Plan

## Summary

Listam should grow from the current mobile app into three coordinated applications:

- **Mobile app:** the existing Expo/React Native app.
- **Desktop app:** an enhanced and optimized large-screen version of the mobile experience.
- **Headless app:** a personal always-on server for devices the user owns.

The apps should live in their own repositories, while shared domain, protocol, backend, and client modules are published as versioned packages from a shared repository. The first milestone should preserve current Listam parity across all app surfaces before expanding into richer personal-life-management list types.

## Review Findings And Required Fixes

This section records a security and architecture review of this plan against the current `listam-mobile` implementation (review date 2026-05-29). Items are ordered by severity. **Critical and High items should be treated as blocking acceptance criteria and resolved before package extraction or the desktop/headless split begins**, because every multi-app, owner-control, and co-invite feature in this plan inherits the assumptions below.

The root issue: this plan layers a rich role / permission / revocation / "minimum-credential" vocabulary on top of an Autobase + BlindPairing substrate that, as implemented, only supports **"full writer holding the encryption key"** or **"no access."** Several headline promises are therefore not achievable with the current architecture without new work.

### Critical

**C1 — "Revoke" is promised but is not achievable with the current model.**

- Finding: Joining appends `{ type: 'add-writer', key }` (`backend/lib/network.mjs`), and `apply` calls `host.addWriter(writerKey, { indexer: true })` (`backend/backend.mjs`). Autobase membership is append-only; there is no `remove-writer` operation anywhere. Revoking an *invite* does nothing to a peer that already joined.
- Fix: Separate "revoke invite" (stop new joins) from "revoke access" (remove an existing member). True member removal requires an app-level membership/ACL layer with encryption-key rotation plus re-encryption and re-invite of the remaining members — a distinct workstream. Until that exists, the plan must state plainly that existing writers cannot be removed without re-keying the base. Do not ship a "remove member" control that only deletes invite material; it gives users false assurance.

**C2 — Role-scoped "minimum credentials" (storage-only / relay-only with read) are cryptographically unsupported.**

- Finding: The host confirms pairing with both `autobase.key` and `autobase.encryptionKey`. With this stack there are only two meaningful states: (a) holds the encryption key → can decrypt everything and is one append away from writing; (b) holds no key → opaque ciphertext only (true blind relay, cannot read or sync content). There is no "read but not write" and no "sync but cannot decrypt."
- Fix: Re-scope the headless role table. "Blind storage / relay" = ciphertext only, no encryption key. Any role that can read or sync content necessarily has full read access and must not be labelled as containment. Resolve this before the headless co-invite milestone.

**C3 — Any writer can add further writers; there is no owner authority.**

- Finding: `apply` honours `add-writer` from any node in the replicated log, and every writer can append. Any joined writer can silently add more writers (as indexers), with no owner-only gate, threshold, or audit trail.
- Fix: Introduce a membership-authority design — a designated owner key that alone may authorize `add-writer`, verified by signature inside `apply` — and make it a milestone deliverable before "shared space" and headless co-invite are built.

### High

**H1 — The P2P owner-control admin channel is the riskiest new surface and is underspecified.**

- Finding: The headless server exposes remote commands including `shutdown`, `export`, `import`, `rotate invite`, and `configure topics` over the DHT. The plan's security treatment is limited to "require pairing/auth," "encrypted," and "authenticated," with no concrete scheme for what authenticates each command (no signature / nonce / replay design beyond a `requestId`), how pairing bootstraps trust (BlindPairing yields *writer* access, not an auth channel — a different primitive is needed), or authorization granularity (e.g. whether a diagnostics-only client may issue `shutdown`). "Owner-control tokens" as listed are unscoped bearer tokens.
- Fix: Specify an authenticated-capability design before implementation: per-device key pairs established at pairing; every command signed and carrying a nonce/timestamp for replay protection; capabilities scoped per paired device (read / configure / admin / shutdown as separate grants); tokens device-bound and rotatable. Make this design an explicit milestone deliverable.

**H2 — Deep links auto-join with no user confirmation (base-hijack / phishing).**

- Finding: The frontend registers `Linking.getInitialURL()` and a `url` listener that calls `startJoinWithInvite()` directly, which sends `RPC_JOIN_KEY` with no confirmation dialog. `joinViaInvite` tears down the current base and switches to the invite's base. The app also generates `https://listam.ch/join?invite=...` links for sharing. Opening a crafted link can therefore switch a user onto an attacker's base without consent.
- Fix: Require an explicit, user-visible confirmation before any join initiated from a link (show who/what is being joined), and never tear down the current base until the user confirms. Apply the same rule on desktop.

**H3 — Invites are reusable, effectively non-expiring, and persisted as unused plaintext bearer secrets.**

- Finding: `INVITE_MAX_USES = 10` — one shared link onboards up to ten permanent writers by default. `inv.expires` is stored but never checked, so invites do not actually expire. `saveInvite()` writes the invite (a bearer credential) to plaintext `lista-invite.json`, but `loadInvite()` is never called — `initAutobase` always mints a fresh invite, so the file is pure liability with no benefit.
- Fix: Default to single-use, short-lived invites and enforce expiry in code. Delete the unused invite persistence rather than migrating it; if an invite must persist, secure-store it and bound its lifetime. Note that even a single-use invite grants *permanent* writer access (see C1), so the UI must say so.

### Medium

**M1 — Backend reduces by `text`, but the plan normalizes Redux by `id` → guaranteed divergence.**

- Finding: The backend source of truth keys items by `text`: add/update/delete match on `i.text !== value.value.text`, and `rebuildListFromPersistedOps` builds a `Map` keyed by `item.text`. The plan calls for stable item IDs and Redux normalization by id. Normalizing Redux by id over a text-keyed backend produces two projections that disagree (two ids with the same text collapse in the backend but split in Redux).
- Fix: Migrate the replicated reduction to id-keying *before* the Redux normalization work, with a migration that backfills ids for legacy text-only entries. Sequence this as a prerequisite of the Redux refactor.

**M3 — The `loyaltyCards` Redux slice contradicts the plan's own secure-storage requirement.**

- Finding: The plan puts loyalty cards in a Redux slice *and* requires their barcode/QR payloads to live in secure storage and be redacted from DevTools-style traces. Redux state is serializable, inspectable, and commonly persisted — routing a secret through it fights the secure-storage goal.
- Fix: Keep secret payloads out of Redux. Store only non-secret metadata/handles in the slice and fetch the secret on demand from secure storage at render time.

**M4 — Corruption "recovery" silently destroys user data — dangerous for the headless storage role.**

- Finding: On an Autobase `ready()` error the code deletes the key file and the entire base storage and recreates a fresh base — wiping identity and data on a parse error, with no backup or consent. For the planned "storage helper" (the durable redundant copy) this could destroy the only retained copy.
- Fix: Require backup/export-before-wipe and owner notification; never auto-wipe a storage-helper node. Make corruption recovery a user/owner-confirmed action.

**M5 — The redaction layer is bypassable, and logs are committed to the repo.**

- Finding: The plan's redaction depends on routing through `@listam/logging`, but the current code prints raw secrets via `console.error` pervasively: full base key on save, base/writer keys and encryption-key prefix during init, and full item payloads in `apply`. A shared logging package only helps code that uses it. Additionally, `app/logs_bare_backend` and `app/logs_react_frontend` are committed to the repository.
- Fix: Add an enforcement mechanism (eslint `no-console` / banned-API rule plus a CI grep gate for secret-shaped strings) so raw logging cannot regress. Remove committed log files and gitignore them.

### Lower Severity (efficiency and correctness the milestone inherits)

- **Full-view replay on every sync.** `rebuildListFromPersistedOps` replays the entire view from index 0 and runs inside the 1-second `waitForWritable` poll (up to ~120× per join). O(n·attempts) with no checkpoint; degrades on an always-on headless node with a growing log. Fix: add a materialized-view checkpoint/snapshot the rebuild can resume from.
- **Full-list pushes instead of diffs.** `SYNC_LIST` sends the entire list and is re-sent on poll ticks. The protocol should make per-item events the default and snapshots the exception, especially over future P2P event streams.
- **Fragile join state machine.** `_writableCheckTimer` is shared between `waitForWritable` and `waitForPeerConnection` (overlapping-timer risk), and the module-global `_writeChain` is never reset across base teardown/reinit, so in-flight writes can target the wrong base after a join switch. Add explicit per-base write contexts and distinct timers; cover with join-rollback tests.
- **Singleton lock won't survive the multi-app model.** `lista.lock` is opened `wx` with cleanup only on `teardown`, so a hard crash leaves a stale lock, and it cannot coordinate the multiple processes (desktop + headless on one machine) the plan introduces. Add a real lock/lease (or distinct storage roots) and stale-lock recovery.
- **No resource limits on headless relay / store-and-forward.** Queueing others' encrypted messages introduces storage-exhaustion and relay-abuse surface with no quotas, queue caps, or rate limits, and the first-milestone scope is narrower than the capability list. Defer relay/storage-for-others past milestone 1 and add explicit quotas/rate limits when introduced.
- **No CI/test bootstrap step.** The repo currently has zero tests and gitignores `package-lock.json`. The plan makes tests acceptance gates but never includes standing up a test runner + reproducible-install CI. Add this as milestone-zero.

## Implementation Plan For Review Findings

Each finding above must have an implementation path, acceptance signal, and test coverage before it can be considered closed. The core strategy is to harden the existing mobile app and backend first, then extract shared boundaries, then build desktop/headless on top of those proven boundaries.

### Critical Finding Plans

**C1 — Revoke is not achievable with the current model.**

Implementation plan:

- Rename current UI/API language so "revoke invite" only means "stop future joins." Do not present it as removing an already joined member.
- Remove any planned "remove member" control until a true membership model exists.
- Add an app-level membership record with owner-controlled epochs: owner key, member writer keys, role labels, membership version, and audit metadata.
- Add key-rotation/re-key flow for true member removal: create a new encryption epoch or base, migrate/re-encrypt the current snapshot and future operations, re-invite remaining members, and mark the old epoch read-only/retired.
- Add audit events for invite revoke, access re-key, member removal, and re-invite results.

Acceptance signal:

- Revoking an invite prevents new joins but does not claim to remove existing members.
- Removing an existing member requires a completed re-key flow, and the removed device can no longer decrypt or append accepted operations in the active epoch.
- Tests cover invite revoke, member removal re-key, old-member append rejection, and rollback if re-key fails midway.

**C2 — Role-scoped minimum credentials are cryptographically unsupported today.**

Implementation plan:

- Split roles into **currently supported** and **future permission-model** roles.
- Current supported roles are: trusted writer/full participant, and blind relay/storage that receives no encryption key and cannot read list content.
- Remove or caveat any "storage with read/sync but no write" language until a distinct reader credential and writer authorization model exists.
- Add a separate blind-storage invite path if the app needs ciphertext-only replication helpers; it should share only topic/base metadata needed to store encrypted blocks, not content encryption keys.
- Design future reader/content-sync roles only after membership authority and key epochs exist.

Acceptance signal:

- The UI and docs never claim read-only or sync-only access with the current BlindPairing writer invite.
- Headless co-invite options make clear whether the target is a trusted full participant or a blind helper that cannot inspect content.
- Tests prove relay/storage helpers do not receive the Autobase encryption key unless explicitly configured as trusted full participants.

**C3 — Any writer can add further writers.**

Implementation plan:

- Introduce owner-signed membership operations, for example `membership/add-writer@v1`, that include owner public key, target writer key, member role label, operation id, timestamp, and signature.
- Persist an owner authority key during base creation and migrate existing single-user bases by treating the current local writer as the initial owner.
- Update `apply` so raw unsigned `{ type: 'add-writer' }` is accepted only during a tightly scoped legacy migration window, then rejected.
- Add audit logging for accepted and rejected membership operations.
- Add a recovery path for owner-key loss before making owner-only membership mandatory.

Acceptance signal:

- A non-owner writer cannot add another writer by appending `add-writer`.
- Legacy bases can migrate once without losing the existing owner device.
- Tests cover owner add success, non-owner add rejection, malformed signature rejection, replayed membership op rejection, and migration compatibility.

### High Finding Plans

**H1 — P2P owner-control admin channel is underspecified.**

Implementation plan:

- Define a separate owner-control protocol before implementation, independent of BlindPairing list invites.
- Pair each trusted device with a long-lived device key pair and store the private key in platform secure storage.
- Require every command to include command id, device id, capability scope, timestamp, nonce, payload hash, and signature.
- Track used nonces or monotonic counters per device to reject replayed commands.
- Model capabilities as separate grants, such as `status:read`, `diagnostics:read`, `topics:configure`, `invite:create`, `export:create`, `import:apply`, and `service:shutdown`.
- Make owner-control grants rotatable and revocable per device, with audit logs and visible device management UI.

Acceptance signal:

- Headless refuses unsigned, replayed, expired, or out-of-scope commands.
- A diagnostics-only client cannot issue shutdown, import, export, or topic configuration.
- Tests cover pairing bootstrap, signed command success, replay rejection, capability rejection, device revocation, and key rotation.

**H2 — Deep links auto-join with no user confirmation.**

Implementation plan:

- Parse link-initiated invites into pending state instead of calling `RPC_JOIN_KEY` immediately.
- Show a confirmation screen/dialog that explains the invite source, the current-list impact, and that joining may switch the active base.
- Do not tear down the current base or send the join RPC until the user confirms.
- Keep manual paste-join explicit, but show the same warning before switching bases.
- Preserve the existing rollback path and add a visible failure state if pairing or permission times out.

Acceptance signal:

- Opening `https://listam.ch/join?invite=...` cannot switch bases without a tap/click confirmation.
- Cancel leaves the current list/base untouched.
- Tests cover cold-start deep link, foreground link, duplicate link suppression, cancel, confirm, failed join rollback, and desktop parity.

**H3 — Invites are reusable, non-expiring, and persisted as unused plaintext bearer secrets.**

Implementation plan:

- Change the default invite policy to single-use with short enforced expiry.
- Check expiry and remaining uses before confirming BlindPairing candidates.
- Delete the unused plaintext `lista-invite.json` persistence. If persisted invites become necessary later, store them in secure storage with TTL metadata and audit trails.
- Rotate invite material after use, expiration, manual revoke, or access-mode change.
- Show lifetime, use count, and permanent-writer warning in the invite UI until true member removal exists.

Acceptance signal:

- Expired or exhausted invites cannot add peers.
- Plaintext invite files are no longer created in production mode.
- Tests cover expiry, use exhaustion, rotation, manual revoke, restart behavior, and redacted invite logs.

### Medium Finding Plans

**M1 — Backend keys items by text while Redux is planned by id.**

Implementation plan:

- Version list operations so new operations require stable `id`, while legacy text-only operations remain readable.
- Backfill deterministic ids for legacy entries during migration, using operation position plus normalized text or another collision-resistant legacy key.
- Change add/update/delete reduction to key by `id` when present and fall back to the legacy text key only for old entries.
- Emit backend snapshots with ids before normalizing Redux entities by id.
- Keep UI behavior compatible for existing lists, but allow duplicate item names after migration.

Acceptance signal:

- Backend materialized view and Redux projection agree for duplicate item names.
- Existing text-only lists migrate without losing done state or order.
- Tests cover legacy replay, duplicate text entries, update/delete by id, and mixed legacy/new operation logs.

**M3 — Loyalty-card Redux slice conflicts with secure storage.**

Implementation plan:

- Store only non-secret record handles and safe display metadata in Redux; if card names or barcode types are considered sensitive, store those in secure storage too.
- Keep barcode/QR payloads, raw scans, and exportable card details in platform secure storage.
- Load secret payloads only inside the scanner/viewer flow and clear them from memory when the view closes.
- Redact loyalty card payloads from logs, diagnostics, Redux traces, screenshots, and crash reports where the platform permits.

Acceptance signal:

- Redux DevTools-style traces and persisted Redux state never contain card payloads.
- Existing AsyncStorage loyalty cards migrate into secure storage.
- Tests cover migration, render-time secret fetch, delete, export, and redaction.

**M4 — Corruption recovery silently destroys user data.**

Implementation plan:

- Replace auto-wipe with quarantine: move or mark the suspect storage root, keep the key material untouched, and start a recovery flow.
- On user-facing apps, show a recovery prompt with backup/export, retry, fresh-base, and support-diagnostics options.
- On headless/storage helper nodes, stop destructive recovery entirely and notify owner clients over CLI/owner-control.
- Create an encrypted backup before any destructive repair.
- Log recovery events without raw keys or content.

Acceptance signal:

- A corrupted Autobase/Corestore state never triggers silent deletion.
- Headless nodes refuse auto-wipe and remain available for owner-directed recovery.
- Tests cover corrupt store detection, quarantine, backup-before-wipe, user cancel, owner-approved fresh base, and recovery logs.

**M5 — Redaction layer is bypassable and logs are committed.**

Implementation plan:

- Add a shared logger, but also enforce its use with eslint `no-console` or a banned-API rule for production code.
- Add CI grep/secret-shape checks over source, generated logs, and exported diagnostic bundles.
- Remove committed runtime logs and add ignore rules for local log outputs.
- Add explicit ignore rules for generated P2P secret/runtime files, including `autobase-key.txt`, `local-writer-key.txt`, `encryption-key.txt`, `invite.json`, `lista-autobase-key.txt`, `lista-local-writer-key.txt`, `lista-encryption-key.txt`, and `lista-invite.json`.
- Add redaction helpers for keys, invite codes, topic ids, item payloads, card payloads, auth headers, and owner-control material.
- Gate debug/trace logging by build mode and explicit user/developer consent.

Acceptance signal:

- Production code cannot introduce raw `console.log`/`console.error` without a lint failure.
- Secret-shaped values fail CI if they appear in logs or fixtures outside explicit redaction tests.
- Tests cover logger redaction, export redaction, peer-log bundle redaction, and retention/rotation.

### Lower-Severity Finding Plans

- **Full-view replay:** add materialized-view checkpoints or snapshots with last processed index; acceptance is replay that resumes from checkpoint and bounded join polling work.
- **Full-list pushes:** make item-level protocol events the default and use snapshots only for initial hydration, repair, or missed-event recovery; acceptance is no repeated full-list push during steady-state polling.
- **Fragile join state machine:** introduce per-base join/write contexts, reset write queues on base teardown, separate writable and peer timers, and add join rollback tests.
- **Singleton lock:** replace the simple `wx` lock with a lease containing owner pid/instance id, heartbeat, stale-lock recovery, and separate storage roots for desktop/headless when appropriate.
- **Headless relay resource limits:** defer third-party store-and-forward past milestone 1; when added, enforce per-topic quotas, queue caps, TTLs, rate limits, and owner-visible storage usage.
- **CI/test bootstrap:** create milestone-zero CI with a reproducible lockfile, unit test runner, lint, dependency hygiene check, redaction scan, and at least backend reducer/join/security smoke tests.

## Overall Strategy Improvements

- Make milestone zero explicit: security hardening, test bootstrap, reproducible installs, and documentation alignment should land before Redux/package extraction.
- Sequence the risky substrate work before product expansion: membership authority, invite lifecycle, deep-link confirmation, secret storage, and log enforcement come before desktop/headless trust features.
- Stand up the separate app repositories and the shared package repository early, and decouple `@listam/backend` from BareKit-specific globals so the published backend package runs under mobile worklet, Pear Desktop, and headless Bare/Node alike.
- Before implementing UI for any app or project, check for a project-local `design-guide/` directory. When it exists, its design system docs, tokens, component rules, and example screens are the UI source of truth and must guide implementation and review before generic visual preferences.
- Treat UI internationalization as shared product infrastructure before desktop parity: user-facing strings, locale preferences, plural rules, date/number formatting, fallback behavior, and long-string/RTL layout checks should be solved once for mobile and desktop rather than retrofitted per app.
- Treat headless roles as capability tiers with honest credential boundaries. The current safe tiers are trusted full participant and blind ciphertext helper; richer read-only/sync-only roles are future work.
- Define contract tests at every boundary: RPC numbers, protocol events, package exports, storage migrations, owner-control commands, and cross-app sync.
- Add a release gate checklist so each milestone has explicit "docs updated, wiki aligned, tests passing, security review updated" acceptance.

## State Management Decision

After milestone-zero hardening, use **Redux Toolkit** as the state manager before building desktop and headless apps.

Redux Toolkit is the better fit for the intended future direction:

- multiple list types, including to-dos, simple tasks, calendar-derived lists, and kanban boards
- configurable rules and state transitions
- normalized entities shared by mobile and desktop UIs
- predictable actions for debugging and auditability
- cleaner cross-app contracts between UI state, replicated backend state, and local preferences

Autobase/Corestore remains the durable local-first source of truth for replicated data. Redux becomes the UI projection, command dispatcher, and shared app-state model.

## Repository And Package Topology

Use separate application repositories for milestone 1:

- `listam-mobile`: the existing Expo/React Native app.
- `listam-desktop`: the planned Pear Desktop app.
- `listam-headless`: the planned Pear Terminal/Bare personal server.

Create one shared package repository:

- `listam-shared`

The shared repository publishes versioned npm packages consumed by all app repos:

- `@listam/domain`: domain types, Redux slices, selectors, migrations, and shared business rules.
- `@listam/protocol`: command and event contracts between UI clients, backend services, and future relay devices.
- `@listam/backend`: Bare-compatible Autobase/Corestore/Hyperswarm service code, kept free of platform-specific globals so it runs under the mobile worklet, Pear Desktop, and headless Bare/Node.
- `@listam/client`: platform adapters for mobile worklet RPC, Pear Desktop IPC, and headless P2P owner-control clients.
- `@listam/logging`: shared append-only log writer, log schema, redaction rules, rotation policy, diagnostics readers, and export helpers.
- `@listam/secrets`: shared secret names, key fingerprints, migration contracts, redaction helpers, and platform secret-store interfaces.
- `@listam/i18n`: typed UI message catalogs, locale detection/selection contracts, fallback rules, plural/date/number formatting helpers, and pseudo-locale test utilities.
- `@listam/grocery`: grocery category, translation, grouping, and icon intelligence currently living in mobile UI modules.

This keeps each application independently releasable while making shared updates explicit and repeatable through package versions. To make the shared `@listam/backend` package portable across all three apps, decouple it from BareKit-specific globals (`BareKit.IPC`, `Bare.argv`, `Bare.on('teardown')`) behind a small platform-services adapter, and keep per-platform `bare-pack` bundling an app-level build step.

## Client Adapters

`@listam/client` should provide one common app-facing client interface over different transports. Each client adapter hides the transport details so app code can ask for things like current status, create invite, join invite, subscribe to list changes, or watch peer count without caring whether the backend is embedded in the same process or running as a separate personal server.

The transports differ by app type:

- **Mobile:** uses in-process Bare worklet RPC. The backend is started by the React Native app and communicates over BareKit IPC, so no local HTTP server is needed.
- **Desktop:** uses Pear Desktop IPC for its embedded backend path and may also use the headless P2P owner-control adapter when the desktop app controls or observes a user's always-on personal server on another owned device.
- **Headless:** has no screen UI process and is expected to run on a different always-on device, such as a Raspberry Pi, mini PC, NAS, or other owned server. It needs an owner-control surface so the user's mobile or desktop app can configure it, inspect it, and attach it to topics even when the headless device is not the same machine.

The default headless control surface should be P2P after initial pairing:

- **P2P owner-control command stream:** encrypted request/response commands such as status, create invite, join invite, export, import, rotate invite, shutdown, configure topics, and list known owned devices.
- **P2P owner-control event stream:** encrypted live subscriptions for peer count, sync state, join progress, backend errors, list snapshots, list operations, topic health, queued async messages, storage health, and owned device status.

Initial pairing can use QR code, terminal pairing code, LAN, Bluetooth, USB, Tailscale/MagicDNS, or CLI/SSH. Once paired, mobile and desktop should configure the headless instance through an encrypted owner-control topic instead of requiring a reachable HTTP server. HTTP/API, Tailscale, LAN, and CLI remain useful setup/recovery transports, but they are not the default long-term control plane.

> **Review note (H1):** The owner-control channel is the riskiest new surface (remote `shutdown`/`export`/`import`). Specify an authenticated-capability design before building it: per-device key pairs from pairing, signed commands with nonce/timestamp replay protection, and per-device scoped capabilities (read / configure / admin). Bearer "owner-control tokens" alone are insufficient. See H1 in Review Findings.

## Mobile App

The mobile app should be refactored first because it is the current working product.

Key changes for the state-manager phase:

- Add Redux Toolkit and create the initial store.
- Move list state, sync status, join status, peer count, invite key, preferences, locale choice, and loyalty-card metadata handles into slices.
- Keep short-lived component state local when it is only UI interaction state, such as text input focus or modal visibility.
- Replace direct `useState` ownership of replicated list data with Redux selectors and actions.
- Move backend command side effects into listener middleware or typed thunks.
- Keep the Bare worklet and RPC boundary, but treat it as a platform adapter instead of the owner of UI state.

### Planned Redux Slices

A Redux slice is a focused Redux Toolkit module for one state domain. It contains the initial state, reducers/actions, and selectors for that domain. Listam should use slices so shared mobile/desktop state does not become one large, hard-to-review object.

Initial slices:

- `lists`: replicated list entities, ordering, selected list, and local optimistic list operations.
- `sync`: backend readiness, peer count, invite key, join phase, sync health, and sync errors.
- `preferences`: local UI choices such as grid/list mode, category toggles, category headers, icon size, text size, icon style, locale override, and follow-system-language setting.
- `loyaltyCards`: local loyalty-card metadata handles until/unless those records are later made replicated; barcode/QR payloads stay in secure storage.
- `ownedDevices`: known headless instances and future dongles, including display names, trust status, supported roles, and last-seen status.

> **Review note (M3):** Do not route loyalty-card secrets (barcode/QR payloads) through the `loyaltyCards` slice — Redux state is serializable, inspectable, and often persisted, which conflicts with the secure-storage requirement. Keep only non-secret metadata/handles in Redux and read the secret payload on demand from secure storage.

This structure makes the current app easier to split across mobile and desktop, and it leaves clean extension points for future domains such as tasks, calendar ingestion, kanban boards, configurable rules, and other personal-life-management features.

## UI Internationalization Direction

Listam already has grocery category/item translation data, but the UI chrome should have a separate internationalization layer. Grocery intelligence answers "what is this item called/grouped as"; UI internationalization answers "what does this screen, action, empty state, error, confirmation, and diagnostic label say."

Implementation direction:

- Create a shared `@listam/i18n` package or module before desktop parity so mobile and desktop use the same message keys, fallback chain, and formatting behavior.
- Externalize user-facing UI strings from mobile screens, dialogs, settings, invite/join flows, diagnostics, loyalty-card screens, and desktop-shared components into typed catalogs.
- Keep locale choice in the local `preferences` slice: follow system language by default, allow an explicit override, and persist it as local UI preference rather than replicated list data.
- Support pluralization, interpolation, relative dates, numbers, byte sizes, and list formatting through structured helpers instead of string concatenation.
- Keep grocery category/item translations in `@listam/grocery`, but expose a locale-aware resolver so UI copy and grocery labels share the same selected locale.
- Add pseudo-locale and long-string testing, plus RTL metadata and smoke checks for any locale that needs right-to-left layout.
- Review translated and pseudo-localized mobile/desktop screens against each project-local `design-guide/` examples so longer strings do not overlap controls, truncate critical copy, or break the kinetic/minimalist layout rules.

Acceptance signal:

- User-facing UI copy is routed through typed message keys, with CI failing on missing keys or unsupported interpolation parameters.
- English plus at least one non-English catalog render in mobile; desktop consumes the same catalogs when built.
- Pseudo-locale and long-string screenshots pass for the main list, invite/join confirmation, settings/preferences, diagnostics, and loyalty-card surfaces.
- Locale selection survives restart, honors system-language fallback, and does not replicate to other devices unless a future explicit per-account preference model is added.

## Desktop App

Build the desktop app as a Pear Desktop application first, with Electron as a fallback only if Pear blocks a concrete requirement.

The desktop app should be an enhanced version of the mobile app, not a separate product concept.

Before building or changing desktop UI, read `listam-desktop/design-guide/`. The design system and example screens in that folder are binding references for layout, typography, color, spacing, interaction states, and component behavior. If a future app/project includes its own `design-guide/`, follow that local guide the same way.

First milestone:

- current Listam list parity
- invite creation and joining
- peer and sync status
- list and grid views
- grocery grouping and icon intelligence
- shared Redux/domain logic
- shared backend/client packages

Desktop-specific improvements:

- denser list and grid layouts
- keyboard-first actions
- larger multi-pane structure
- clearer sync and peer diagnostics
- tray or status affordances where Pear Desktop supports them
- easier review of invites, peers, and owned headless-device connections

## Headless App

Build the headless app as a Pear Terminal/Bare personal server.

The headless version should run on always-on devices owned by the user, usually a different device than the user's phone or desktop computer. Good targets include a Raspberry Pi, mini PC, home server, NAS, or other small always-on machine. It should not become a central cloud service. Its role is to act as a durable personal peer that keeps Listam available, helps devices reconnect, and later coordinates with relay/storage dongles.

First milestone:

- run as a long-lived owned peer
- persist the same Autobase/Corestore data model
- create and join invites
- expose peer count, sync state, base identity, and storage status
- provide CLI commands for setup, status, invite, join, export, and shutdown
- expose a P2P owner-control command/event channel for trusted desktop, mobile, and admin clients
- require pairing/auth for control operations and never expose raw control endpoints publicly by default
- guide first-run setup by asking what roles the device should perform and showing the connection details needed to pair it with the user's mobile or desktop app

The P2P owner-control channel exists because headless is a service running on another owned device, not a screen app on the same machine. Mobile and desktop instances need a trusted way to configure and observe it without requiring shared LAN access, exposed ports, or Tailscale. The control plane should be authenticated, pairable from the user's apps, encrypted end to end, and separate from public list replication topics.

First-run setup should ask which capabilities the device should enable:

- **Bootstrap helper:** stay online on known topics so the user's devices have a stable owned peer to find when reconnecting.
- **Replication helper:** join selected Autobase discovery topics and replicate content for lists the user allows.
- **Storage helper:** retain replicated content under a configured storage policy. As a *blind* helper it should not receive the list encryption key (it stores ciphertext it cannot read); only a fully trusted helper that holds the encryption key can read content (see C2). There is no read-only-but-decrypting tier yet.
- **Async message helper:** accept encrypted store-and-forward messages for peers in the same allowed topics and deliver them when peers reconnect.
- **Notification/reconnect helper:** track topic health and queued activity so mobile/desktop clients can show better sync status and eventually trigger push-style notifications.
- **Diagnostics helper:** report peer count, storage usage, queue depth, topic health, protocol version, and recent errors to trusted owner clients.

### Headless Co-Invite Flow

When a user is invited to someone else's list or shared space, Listam should offer the option to also invite the user's trusted headless instances. This keeps the user's always-on personal devices useful even when the first joined device is mobile or desktop.

Flow:

- A user joins someone else's list or shared space from mobile or desktop using the normal invite flow.
- After that device becomes writable or otherwise receives the allowed access mode, the app offers to add the user's known headless instances.
- The user selects one or more owned devices and chooses an access mode, such as writer, storage helper, or relay-only helper.
- The joined device creates a short-lived delegated invite scoped to the target owned device and selected access mode.
- The headless instance accepts the delegated invite through its trusted P2P owner-control channel.
- For writer mode, the joined device appends the writer membership operation needed by the shared space.
- For trusted storage mode under the current substrate, the headless device must be treated as a full trusted participant if it receives list credentials.
- For blind storage or relay-only mode, it avoids list encryption credentials and only receives topic/base metadata needed to store or relay opaque encrypted blocks.

Delegated co-invites should inherit the same lifetime, use-count, expiration, revocation, audit logging, and redaction rules as normal invites. They should also respect the future permission model once it exists. Until then, the UI must describe the honest current choices: trusted full participant, or blind helper with no content access.

> **Review note (C1–C3):** With the current Autobase/BlindPairing model these guarantees are not yet real. Sharing read/sync access means sharing the encryption key, which grants full read and is one append from writing — there is no read-only or sync-only credential (C2). `add-writer` is append-only with no owner gate, so members cannot be revoked and any writer can add writers (C1, C3). Build the membership-authority and key-rotation work first, or scope these promises down to what the substrate supports.

## Logging And Diagnostics Strategy

Listam should have one shared logging strategy across mobile, desktop, headless, backend services, and future dongles. Logs should help the user and developer understand sync, P2P connectivity, storage, pairing, and UI/backend command flow without turning logs into replicated application data.

Use a shared `@listam/logging` package so every app writes the same line format and applies the same redaction and export rules.

### Local Append-Only Logs

Each app instance should write logs to a local append-only file. The default format should be newline-delimited JSON because it is easy to append, stream, search, redact, zip, and import into diagnostic tools.

Suggested local files:

- mobile app: `mobile.log.jsonl`
- desktop app: `desktop.log.jsonl`
- headless app: `headless.log.jsonl`
- embedded backend or service process: `backend.log.jsonl`
- future dongle bridge/companion tooling: `dongle.log.jsonl`

Every log row should include the app or service name so merged logs remain understandable:

```json
{
  "ts": "2026-05-27T12:00:00.000Z",
  "level": "info",
  "app": "mobile",
  "instanceName": "Romme iPhone",
  "instanceId": "device-scoped-stable-id",
  "runtime": "react-native",
  "component": "sync",
  "event": "peer_count_changed",
  "message": "Peer count changed",
  "topicId": "redacted-topic-fingerprint",
  "baseId": "redacted-base-fingerprint",
  "requestId": "command-correlation-id",
  "sessionId": "startup-session-id"
}
```

Recommended levels:

- `trace`: very detailed command/event flow, development only by default
- `debug`: useful development diagnostics
- `info`: normal lifecycle and sync milestones
- `warn`: recoverable problems
- `error`: failed operations that need attention
- `fatal`: startup or persistence failures that prevent normal operation
- `audit`: security-relevant owner actions such as pairing, device trust changes, export, or topic permission changes

Logs should rotate by size and age so always-on instances do not grow without bound. A reasonable starting policy is smaller retention on mobile, larger retention on desktop, and the largest retention on headless devices:

- mobile and desktop: 10 MB per file, 10 rotated files, short production retention
- headless: 50 MB per file, 20 rotated files, longer retention because it is the always-on diagnostic source
- development mode: longer retention and optional `debug` or `trace` logs
- production mode: default to `info` and above, with sensitive fields redacted

### Visibility In All Apps

All user-facing apps should include a diagnostics/logs view. Mobile and desktop should show local logs, backend logs for their embedded backend, and trusted peer log bundles when available. Headless should expose the same information through CLI and P2P owner-control so it can be inspected from mobile or desktop without attaching a monitor.

Useful diagnostics filters:

- app or instance name
- level
- component, such as UI, Redux, client adapter, backend, storage, P2P, pairing, sync, export, or headless service
- topic/list fingerprint
- request or operation correlation ID
- time window
- only warnings/errors

The diagnostics UI should also show a compact health summary derived from logs and status events: peer count, last successful replication, queue depth, storage usage, current protocol version, recent errors, and currently enabled headless roles.

### Development Peer Log Requests

In development mode, each trusted app instance should be able to request logs from peers for debugging. This should use the same trust model as owner-control and explicit development/debug topics, not a public endpoint.

Development log-request flow:

- the developer enables diagnostics sharing on the local device or test group
- a mobile, desktop, or headless instance sends a `requestLogBundle` command to trusted peers
- peers respond with a bounded, redacted log bundle for the requested time window and levels
- the requester merges bundles by timestamp while preserving `app`, `instanceName`, and `instanceId`
- the requester can export the bundle as a zip file, plain JSONL, or email/share-sheet attachment

For normal production users, peer log requests should be disabled by default. The exception can be the user's own paired headless instance over owner-control, where the user explicitly opens diagnostics and requests its logs.

### Redaction And Privacy

Logs must never expose raw secrets by default. Redaction should happen before writing to disk and again before export.

Always redact or fingerprint:

- owner-control tokens
- pairing codes
- invite codes
- base keys
- writer keys
- encryption keys
- raw topic keys
- auth headers or local API tokens
- full user content when a diagnostic event can be useful without it

Prefer short stable fingerprints for correlation, such as the first bytes of a hash, instead of raw keys. Log events should be useful for debugging the system while avoiding the contents of personal lists unless the user deliberately enables a content-including export for a specific debugging session.

### Events Worth Logging

The first logging implementation should cover:

- app startup, shutdown, foreground/background, and version/build metadata
- backend startup, storage path, base opening, writer readiness, and graceful close
- Redux command dispatch, backend command request/response, and operation correlation IDs
- invite creation, join phases, pairing phases, and owner-device trust changes
- peer count changes, discovery state, connection attempts, reconnects, and replication progress
- Autobase append, apply, snapshot, migration, and conflict/reconciliation events
- headless role changes, topic permissions, queue depth, storage usage, and async message delivery
- export/import lifecycle events
- unhandled errors, recoverable errors, and crash reports where the platform permits it

Logs are diagnostics, not the source of truth. Redux may show recent log summaries in diagnostics screens, but the durable app state remains Autobase/Corestore plus local app preferences.

## Key Storage And Secret Handling

The current prototype stores the Autobase key and Autobase encryption key in local text files. That is acceptable only as a development/prototype shortcut. The production multi-app architecture should treat plaintext key files as legacy migration input, not the final storage strategy.

The keys have different risk levels:

- **Autobase/base key:** identifies or bootstraps a replicated base. It is sensitive metadata and should not be logged raw, but it may need to be shared during pairing or recovery.
- **Autobase encryption key:** protects encrypted values. It is highly sensitive and should never remain in plaintext app files for production.
- **Writer keys, owner-control tokens, invite codes, and pairing secrets:** highly sensitive control material that must use platform secure storage and strict redaction.

Production storage strategy:

- keep Corestore, Autobase data, indexes, snapshots, logs, and non-secret metadata in normal app storage
- store encryption keys, owner-control tokens, writer secrets, invite secrets, and pairing secrets in platform secure storage
- store only redacted fingerprints of keys in normal metadata and logs
- pass secrets to the Bare backend at startup through the platform adapter instead of having the backend read long-lived plaintext key files
- keep emergency import/export as an explicit user action with encryption, clear warnings, and audit logging

Platform targets:

- **Mobile:** use iOS Keychain and Android Keystore-backed storage, such as Expo SecureStore or a lower-level native adapter when needed.
- **Desktop:** use the OS keychain where possible. If a platform keychain is unavailable, use a file encrypted with a device-local key or user passphrase and strict file permissions.
- **Headless:** use the OS keyring, TPM-backed secret store, systemd credentials, encrypted local key file, or user-provided passphrase depending on the target device. Plain files should require explicit development mode.
- **Dongle tooling:** avoid storing raw application encryption keys on generic relay hardware unless the device is explicitly acting as trusted storage for the owner.

Migration path from current text files:

- detect legacy plaintext key files on startup
- read and validate the keys once
- write the sensitive values into the platform secret store
- replace normal metadata with fingerprints only
- delete the plaintext files after successful migration
- log only the migration status and fingerprints, never raw key material
- provide a recovery path if secure storage is unavailable or the user is moving to a new device

Reference targets:

- Expo SecureStore: <https://docs.expo.dev/versions/latest/sdk/securestore/>
- Apple Keychain Services: <https://developer.apple.com/documentation/security/keychain-services>
- Android Keystore: <https://developer.android.com/privacy-and-security/keystore>

## Next Implementation Security Hardening

The next implementation pass should remove the current prototype security gaps before the desktop/headless split becomes real. These items should be treated as acceptance criteria for the Redux/shared-package refactor, not as polish after the multi-app architecture exists.

### Secret Storage

Remove plaintext persistence for sensitive secrets:

- migrate `lista-encryption-key.txt` into platform secure storage
- migrate writer keys, owner-control tokens, invite secrets, and pairing secrets into platform secure storage
- treat `lista-autobase-key.txt` as sensitive metadata and either move it to secure storage or store only a protected/fingerprinted representation outside secure storage
- delete unused plaintext `lista-invite.json` persistence; if future persisted invites are required, keep them short-lived, revocable, and secure-store backed
- move loyalty card barcode/QR payloads out of AsyncStorage and into platform secure storage
- keep AsyncStorage only for low-risk preferences such as grid/list mode, icon size, text size, and local UI toggles

### Production Log Safety

Replace direct verbose logging with the shared logging layer:

- remove raw `console.error`/`console.log` output for base keys, encryption keys, local writer keys, invite codes, peer keys, pairing payloads, item payloads, and loyalty card data
- log only redacted fingerprints for keys and topics
- add log-level gates so production builds default to `info`, `warn`, `error`, `fatal`, and carefully scoped `audit` events
- keep `trace` and sensitive command-flow diagnostics development-only
- update repository ignore rules so local logs and generated P2P key/invite files cannot be accidentally committed (`autobase-key.txt`, `local-writer-key.txt`, `encryption-key.txt`, `invite.json`, `lista-*.txt`, `lista-invite.json`)
- add automated checks that fail if known secret-shaped values appear in local logs or exported peer bundles

### Invite Lifecycle Controls

Make invite security visible and controllable:

- add user-facing revoke and rotate controls for active invites
- show invite lifetime, remaining use count, and whether an invite can add writers, storage helpers, or relay-only peers
- prefer short-lived single-use or explicitly bounded-use invites by default
- revoke persisted invite material when the user rotates, leaves a shared space, or disables sharing
- emit audit log events for invite creation, share, use, revoke, rotate, and expiration without logging the raw invite
- ensure headless co-invites and delegated invites inherit scoped lifetime and access mode rules

> **Review note (C1, H2, H3):** "Revoke" must distinguish stopping new joins (possible) from removing an existing member (not possible without re-keying — see C1). Change the default from 10-use, non-expiring invites to single-use with enforced expiry; today `inv.expires` is never checked and the persisted `lista-invite.json` is written but never read (delete it). Also require explicit user confirmation before any link-initiated join, which currently auto-joins and tears down the current base (H2).

### Loyalty Card Privacy

Treat loyalty cards as sensitive local data:

- store card names, barcode values, QR values, and barcode types in secure storage
- keep loyalty cards local-only unless the user explicitly chooses future replication
- redact loyalty card payloads from logs, diagnostics exports, Redux DevTools-style traces, and screenshots where possible
- add delete/export flows that clearly describe whether card data stays local or is included in an export

### Automated Test And Recovery Coverage

Add test coverage before expanding the app surfaces:

- item reduction tests for add, update, delete, complete/uncomplete, and replay order
- duplicate-handling tests for legacy text-only items and future stable item IDs
- category lookup and grocery-intelligence tests that run in CI
- invite join success, join timeout, join rollback, and delegated headless co-invite tests
- corruption recovery tests for invalid local Autobase/Corestore state
- storage migration tests from plaintext key files and AsyncStorage loyalty cards into secure storage
- production-log redaction tests
- invite revoke/rotate tests

### Dependency Hygiene

Make imported runtime modules direct dependencies:

- add direct dependencies for modules imported by loyalty card rendering, including `react-native-svg` and `qrcode-terminal`
- verify whether `@expo/vector-icons` should be a direct dependency or is intentionally supplied by the Expo SDK setup
- add a dependency audit/check that fails when source files import undeclared packages
- keep shared package dependencies explicit so mobile, desktop, and headless do not accidentally rely on transitive packages

## Shared Data Model Direction

The first milestone should keep current simple Listam behavior, but the shared domain model should be ready for richer future list types.

Near-term model direction:

- use stable item IDs when available
- preserve compatibility with old entries that only have `text`
- normalize entities in Redux
- keep operation contracts append-only and versioned
- avoid embedding UI-only concepts into replicated backend operations

> **Review note (M1):** The backend currently keys items by `text`, not `id` (add/update/delete and the view rebuild all match on `text`). Normalizing Redux by `id` on top of a text-keyed backend will diverge. Migrate the replicated reduction to id-keying (backfilling ids for legacy text-only entries) *before* the Redux normalization work.

Future domains:

- simple shopping lists
- to-do lists
- task lists
- calendar-ingested lists
- kanban-style boards
- configurable state machines and rules
- additional personal-life-management features

## Future Dongle Compatibility

The dongles should not be Listam-specific. They should work with every app using the Holepunch stack.

Prototype hardware under consideration:

- Seeed Studio XIAO ESP32S3 with 2.4 GHz Wi-Fi, BLE 5.0, dual-core
- ESP32-S3 DevKitC-1 N16R8
- SPI microSD card reader module for ESP32
- 32 GB microSDHC cards

Planned dongle capabilities:

- P2P bootstrap assistance
- async message relay
- blind relay mode
- reliable redundant storage
- store-and-forward messages for offline peers
- push notification relay
- reconnection assistance
- media streaming and distribution improvement
- Bluetooth configuration for relay topics and behavior

The shared protocol package should keep relay envelopes generic and encrypted. The relay should understand topics, routing hints, storage policy, and delivery metadata, but not Listam-specific list payloads.

## First Milestone

The first milestone should prove current Listam parity across three app surfaces:

- mobile app remains functional after Redux refactor
- desktop app can run the shared backend and sync with mobile
- headless app can run as an always-on peer and sync with mobile/desktop
- all three consume the same shared package versions
- invite and join flow works across app types
- existing simple list operations remain compatible

Do not add new list domains in the first milestone. Add the architecture that makes them possible.

## Test Plan

Redux and domain tests:

- reducers for add, update, delete, sync snapshot, preferences, and join state
- selectors for active list, grouped list, peer status, and UI preferences
- migration tests for legacy text-only items

UI internationalization tests:

- message-catalog completeness tests for every supported locale and namespace
- interpolation/plural/date/number formatting tests for invite, sync, diagnostics, settings, and loyalty-card copy
- pseudo-locale and long-string render tests for the main list, join confirmation, settings, diagnostics, and loyalty-card surfaces
- locale preference tests for follow-system, explicit override, restart persistence, and fallback behavior

Backend and protocol tests:

- command/event contract tests for add, update, delete, snapshot sync, invite creation, join phases, peer count, and errors
- persistence restart test proving Autobase data rebuilds Redux state
- compatibility test for existing RPC command numbers

Logging and diagnostics tests:

- append-only JSONL writer test for mobile, desktop, headless, and backend labels
- redaction tests for invite codes, pairing codes, owner-control tokens, base keys, writer keys, encryption keys, and raw topic keys
- rotation and retention tests for mobile/desktop/headless defaults
- log export test that merges peer bundles by timestamp while preserving app and instance identity
- development peer-log request test over the trusted owner-control/debug channel

Key storage and secret-handling tests:

- legacy plaintext key migration test that writes secrets to secure storage and deletes the old files
- startup test that passes secrets from the platform adapter to the Bare backend without persistent plaintext files
- fallback test for desktop/headless secure-storage-unavailable cases
- redaction test proving raw Autobase keys, encryption keys, writer keys, owner-control tokens, invite codes, and pairing secrets never appear in logs or exports
- AsyncStorage loyalty-card migration test that moves barcode and QR payloads into secure storage
- secure-storage delete/export test for loyalty card records

Invite lifecycle tests:

- invite revoke and rotate tests
- bounded-use invite test proving exhausted invites cannot add more peers
- invite expiration test
- headless delegated co-invite access-mode test for writer, storage, and relay-only modes

Data reduction and recovery tests:

- item reduction tests for add, update, delete, complete/uncomplete, and replay order
- duplicate-handling tests for legacy text-only items and future stable item IDs
- category lookup and grocery-intelligence tests in CI
- join rollback test that restores the previous base/list after failed pairing or permission timeout
- corruption recovery test for invalid local Autobase/Corestore state
- dependency hygiene test for undeclared runtime imports

Cross-app tests:

- mobile-to-desktop sync through invite
- mobile-to-headless sync through invite
- desktop-to-headless sync through invite
- headless restart preserves identity, storage, and status
- shared package version update tested across the mobile, desktop, and headless repos

Manual acceptance tests:

- create an item on mobile and see it on desktop
- mark an item done on desktop and see it on mobile
- keep headless running while mobile is closed, then reopen mobile and verify sync
- create an invite from headless and join from desktop
- verify desktop remains useful without the mobile device online
- compare each implemented UI against any project-local `design-guide/` design system and examples, including `listam-desktop/design-guide/` for desktop, in English and pseudo-localized/long-string modes, and resolve mismatches before acceptance

## Per-App Testing And Cross-Instance Interaction

This section is written for the implementation agents building each app. It defines how to test each surface in isolation **and** how to prove that mobile, desktop, and headless instances actually interact. Every implemented feature should ship with the relevant unit/integration tests below, and every cross-app capability is "done" only when its row in the interaction matrix passes.

### Shared Local Test Harness

Running several instances on one machine (or in CI) requires deterministic isolation:

- **Separate storage roots:** start each instance with its own base directory. Mobile uses the Expo document dir; desktop and headless take a `--storage <dir>` flag. Never share `lista-local` between instances.
- **Private DHT bootstrap:** run a local `hyperdht` bootstrap node and pass its address via a `BOOTSTRAP` / `--bootstrap` option so test peers discover each other without touching the public DHT. Provide a one-command testnet bootstrap for CI.
- **Headless harness commands:** the headless app must expose scriptable primitives the interaction tests drive — `create-base`, `print-invite`, `join <invite>`, `status` (writable, peer count, base id), `dump-list`, `add-item`, `edit-item`, `mark-done`, `delete-item`, `export`, `import`, `shutdown`.
- **Content operation suite:** every shared harness run must generate content, edit it, mark it done/undone, delete it, and assert the resulting snapshot syncs across peers. Assertions compare canonical item ids and tombstones/deletion state, not display names, so duplicate-name content cannot collapse by text.
- **Deterministic teardown:** every test closes stores, destroys swarms, releases the lock, and removes temp dirs. Seeded keypairs make assertions reproducible.
- **Device-to-device mobile:** use two simulators/emulators, or one simulator plus a headless peer.

### Mobile Testing

- **Unit:** reducers/selectors; category lookup and grocery intelligence; item reduction/replay order; id-migration of legacy text-only items (M1); redaction helpers (M5).
- **Integration:** worklet RPC round-trips (add/update/delete → backend → `SYNC_LIST` / `*_FROM_BACKEND`); join success/timeout/rollback; secure-storage migration of keys and loyalty cards; deep-link join requires explicit confirmation (H2).
- **Manual / E2E:** the parity checklist on iOS and Android; offline edit then reconnect-sync; restart persistence.
- **How to run:** `npm test` (Jest/Vitest, added in milestone-zero); Expo dev client for manual runs; two simulators for device-to-device.

### Desktop Testing

- **Unit:** the shared `@listam/domain`, `@listam/protocol`, `@listam/i18n`, and `@listam/grocery` suites run in Node — identical to mobile.
- **Integration:** the Pear Desktop IPC adapter passes the same `@listam/client` contract tests as the worklet adapter; keyboard-action and multi-pane behavior; the diagnostics panel reads backend events.
- **Manual / E2E:** the parity checklist on macOS/Windows/Linux; tray/status where Pear supports it; compare the UI against `listam-desktop/design-guide/`.
- **How to run:** launch the Pear dev app; run the shared package suites with the Node runner; drive a second instance (or a headless peer) for sync.

### Headless Testing

- **Unit:** backend service logic behind the Node runtime port (no BareKit globals); the `apply` reducer; owner-signed membership verification (C3); corruption quarantine/recovery (M4); redaction (M5).
- **Integration:** CLI commands (setup/status/invite/join/export/shutdown); owner-control auth — signed command accepted, and unsigned/expired/replayed/out-of-scope rejected, capability scope enforced, device revoke (H1); role modes — a blind helper never receives the encryption key (C2); resource quotas on queues and storage.
- **Soak:** a long-lived peer stays up for hours with bounded storage/queue; restart preserves identity, storage, and status.
- **How to run:** `node headless.mjs --storage <dir> --bootstrap <addr>` from the `listam-headless` repo; script invite/join against a second headless or a desktop instance; runnable headlessly in CI.

### Cross-Instance Interaction Matrix

Each row is an automated harness test plus a manual check, using the private bootstrap and per-instance storage roots above.

| Pairing | Must prove |
| --- | --- |
| mobile ↔ mobile | invite/join; both devices generate items, edit text, mark done/undone, delete, and converge; duplicate-name handling by id (M1) |
| mobile ↔ desktop | parity sync both directions for generated, edited, completed, and deleted content; desktop stays usable and records edits/deletes while mobile is offline; reconnect sync converges |
| mobile ↔ headless | headless stays online while mobile is closed; headless accepts generated/edited/deleted content while mobile is absent; reopen mobile → sync; headless export/import round-trip preserves ids, done state, edits, and deletions |
| desktop ↔ headless | invite created on headless, joined from desktop; owner-control from desktop (status/configure); generated, edited, completed, and deleted content syncs both directions |
| 3-way (mobile + desktop + headless) | all converge on the same list after concurrent generate/edit/mark-done/delete operations; kill any one, the others continue; rejoin reconciles without duplicates or resurrecting deleted items |
| membership (security) | owner add-member works; **non-owner `add-writer` is ignored (C3)**; member-removal re-key — the removed instance cannot follow the new epoch (C1) |
| credential boundary | a blind-storage instance replicates but cannot decrypt `view.get()` (C2); a trusted full participant can read |
| invite safety | link-join requires confirmation (H2); an expired or exhausted invite is rejected (H3) |
| owner-control | a replayed/expired/out-of-scope command is rejected; a revoked device is blocked (H1) |
| restart / persistence | each instance rebuilds identical state from disk after restart |

Acceptance: the headless-driven subset of this matrix runs in CI; mobile/desktop E2E rows may be manual but must be documented and repeatable. A capability is "done" only when its matrix row(s) pass.

## Assumptions

- Redux Toolkit is the chosen state manager.
- Current Listam parity is the first multi-app milestone.
- Separate app repositories (`listam-mobile`, `listam-desktop`, `listam-headless`) are used from milestone 1.
- Shared modules are distributed as versioned npm packages from `listam-shared`.
- Pear Desktop and Pear Terminal/Bare are the primary targets.
- Electron is only a fallback if Pear cannot satisfy a concrete desktop requirement.
- The first milestone should not implement new list types yet.
- Future relay dongles should remain generic for Holepunch-stack apps, not tied only to Listam.
- Plaintext key files are legacy/development-only and should be migrated before production release.

## Phases

Each phase below is a pause gate, not necessarily a single commit. Small phases land as one commit; larger phases (the package extraction, desktop, and headless work) may span several commits. Either way, implementation must pause at the phase boundary — after the phase's work is committed, verified, and recorded — before the next phase begins, and the phase record must capture the full commit range.

After each phase commit, add or update a collapsible phase subsection in this plan and in the wiki's dedicated phase page. The committed phase record must include:

- list of all files modified and the reason for each modification
- list of all functions created, updated, or deleted and the reason for each action
- general summary of implementation decisions and actions
- commit range (one or more hashes), commit message(s), verification commands, and any follow-up risks

Use this phase-log template after each commit:

<details>
<summary>Phase N - Phase title (commits: pending)</summary>

#### Files modified

- `path/to/file`: reason for modification

#### Functions created / updated / deleted

- `functionName`: created / updated / deleted - reason for action

#### Implementation summary

- Decisions and actions taken during this phase.
- Verification performed.
- Commit range, dependencies satisfied, and acceptance signal met.
- Follow-up risks or blockers.

</details>

### Commit-Worthy Phase List

After Phase 1, the work splits into two tracks that run independently and reconverge before the desktop/headless build. Each phase lists its dependencies explicitly so the tracks can be sequenced or parallelized.

- **Membership-crypto track (Phases 2-4):** secret-storage foundation, owner membership authority, and key epochs / member-removal re-key. This is the highest-uncertainty substrate work (findings C3 and C1). Secret storage comes first because Phases 3-4 mint new long-lived key material that must be born in secure storage, not retrofitted.
- **Data-model and extraction track (Phases 5-8):** stable item IDs, the in-place Redux migration, and the shared-package extraction. It depends only on Phases 0-1, not on the membership-crypto track, so it does not wait behind the re-key flow.

Both tracks must land before Phase 11 onward. Phase 9 adds shared UI internationalization before desktop/headless screens are built; Phase 10 finishes loyalty-card secret migration and logging redaction before durability and release-readiness work.

<details>
<summary>Phase 0 - Test, CI, and repo hygiene bootstrap (listam-mobile commit ef7b181)</summary>

Commit boundary: add a reproducible test runner, commit/un-gitignore the lockfile, a dependency-hygiene check that fails on undeclared runtime imports, a secret/log grep gate, a `no-console` lint rule for production code, and CI entry points; remove committed runtime logs and add ignore rules for generated key/invite files (`autobase-key.txt`, `local-writer-key.txt`, `encryption-key.txt`, `invite.json`, `lista-*.txt`, `lista-invite.json`). No product behavior change.

Depends on: none. Unblocks: all.

Acceptance: CI installs from the lockfile and runs tests, lint, and the grep gate green; no committed logs or secret-shaped strings remain in the repo.

Pause gate: commit the bootstrap, record the modified files/functions, and wait before implementing security fixes.

#### Files modified

- `.gitignore`: un-ignore `package-lock.json` (lockfile is now committed); add `.DS_Store`, `__pycache__/`, `*.pyc`.
- `package.json`: add `test`, `lint`, `check:deps`, `check:secrets`, and aggregate `ci` scripts; declare previously-undeclared runtime deps (`react-native-svg`, `qrcode-terminal`, `@expo/vector-icons`, `bare-path`, `bare-url`); add dev deps `eslint`, `typescript-eslint`.
- `package-lock.json`: **added** — committed for reproducible `npm ci` installs (resolved with `--legacy-peer-deps` due to a pre-existing `react-native-screens` peer requiring RN >=0.82 while the app pins 0.81).
- `eslint.config.mjs`: **added** — flat config enforcing `no-console` for `app/**` and `backend/**` production code; legacy files ratcheted to `warn`; scripts/tests exempt; generated bundles ignored.
- `scripts/check-deps.mjs`: **added** — dependency-hygiene gate.
- `scripts/check-secrets.mjs`: **added** — secret/log grep gate.
- `.github/workflows/ci.yml`: **added** — runs `npm ci` + lint + check:deps + check:secrets + test on push/PR.
- `backend/lib/key.mjs`, `backend/backend.mjs`, `backend/lib/network.mjs`, `app/hooks/_useWorklet.ts`: redact raw key/invite/writer/topic material from log statements (the log lines stay, only the secret values are dropped).
- Deleted from the index: tracked `.DS_Store` files and `scripts/__pycache__/*.pyc`.

#### Functions created / updated / deleted

- `walk`, `packageName` (`scripts/check-deps.mjs`): created — recursive source walk and package-name extraction for the dependency gate.
- `saveAutobaseKey`, `loadAutobaseKey`, `saveLocalWriterKey`, `loadLocalWriterKey` (`backend/lib/key.mjs`): updated — stop logging the raw key hex.
- The `RPC_JOIN_KEY` / `add-writer` handlers (`backend/backend.mjs`) and `initAutobase` / `joinViaInvite` logging (`backend/lib/network.mjs`): updated — drop raw base/invite/writer/topic/encryption-key values from logs.
- No functions deleted.

#### Implementation summary

- Discovered the repo could not `npm install` cleanly at all (no lockfile masked a `react-native-screens` peer conflict); committing a `--legacy-peer-deps`-resolved lockfile is the reproducible-install fix, and CI uses `npm ci --legacy-peer-deps`.
- `no-console` is introduced as a ratchet: new code errors, the ~148 existing calls warn (and are tracked for the Phase 10 `@listam/logging` migration), so the rule lands green without doing Phase 10's work.
- `typecheck` is intentionally **not** in the required `ci` gate: the repo has pre-existing type errors (duplicate keys in the generated `app/components/itemIconMap.ts`, an `IPC` type mismatch in `_useWorklet.ts`) that are out of Phase 0 scope. The `typecheck` script remains available.
- The leftover UI changes from the prior checkpoint were preserved; only hygiene/tooling and secret-log redaction were touched.

#### Verification

- `npm ci --legacy-peer-deps` — installs from the committed lockfile.
- `npm run ci` — green: `eslint .` 0 errors (148 grandfathered warnings); `check:deps` OK; `check:secrets` OK; 3 security tests pass; grocery tests pass.

#### Follow-up risks / blockers

- Pre-existing `tsc --noEmit` errors should be fixed and `typecheck` promoted into the gate (own change, not Phase 0).
- ~148 grandfathered `no-console` warnings remain until the Phase 10 logger/redaction routing.
- Large generated bundles (`app.android.js`, `app.android.mjs`, `backend.bundle.android.js`) are committed and excluded from the lint/secret scans; consider whether they should be tracked at all.
- Commit was made on branch `phase-0-bootstrap` (not pushed).

</details>

<details>
<summary>Phase 1 - Invite safety and deep-link confirmation (listam-mobile commits ee0dd26, a585c4a)</summary>

Commit boundary: stop automatic link joins, add pending-invite confirmation, enforce invite expiry/use limits, remove unused plaintext invite persistence (`lista-invite.json`), and cover join cancel/confirm/rollback tests.

Depends on: 0. Unblocks: -.

Acceptance: a link cannot switch bases without explicit confirmation; expired or exhausted invites are rejected. Rollback: cancel leaves the current base/list untouched.

Pause gate: commit the invite safety work, record the modified files/functions, and wait before changing membership authority.

#### Files modified

- `README.md`: documents Phase 1 invite safety behavior for the mobile repository.
- `app/index.tsx`: routes manual joins and incoming deep links through explicit confirmation before sending `RPC_JOIN_KEY`; confirmation cancel only clears pending state.
- `app/invite-confirmation.ts`: **added** - pure invite normalization, deep-link extraction, pending-confirmation, confirm, and cancel helper logic.
- `app/app.ios.bundle.mjs`, `app/assets/backend.android.bundle.mjs`: regenerated packed Bare backend bundles so the mobile runtime includes the Phase 1 backend changes.
- `backend/backend.mjs`: renames the plaintext invite path export to a legacy cleanup path and routes backend logging through the redacting logger boundary.
- `backend/lib/network.mjs`: reserves invite use before accepting a candidate, rejects stale/expired/exhausted candidates, rotates invites after use/failure, removes legacy invite files, and restores the previous base/list on join failure.
- `backend/lib/invite-policy.mjs`: adds explicit invite-use reservation semantics while keeping invite TTL/use checks centralized.
- `backend/lib/invite-policy.test.mjs`: expands invite expiry/exhaustion coverage with reservation tests.
- `backend/lib/invite-confirmation.test.mjs`: **added** - tests deep-link confirmation, cancel, confirm, invalid, and busy join decisions.
- `backend/lib/join-rollback.mjs`: **added** - testable snapshot/restore helpers for join failure rollback.
- `backend/lib/join-rollback.test.mjs`: **added** - covers rollback snapshots, visible-list restore, and previous-base restore.
- `backend/lib/key.mjs`: renames invite cleanup to `deleteLegacyInviteFile`; backend key/encryption persistence logs go through the redacting logger.
- `backend/lib/logger.mjs`: **added** - structured backend logger with redaction for key-, invite-, byte-, and item-shaped payloads.
- `backend/lib/logger.test.mjs`: **added** - covers logger redaction and level parsing.
- `backend/lib/item.mjs`: routes backend item mutation/rebuild logs through the redacting logger and avoids raw item payload logging.
- `eslint.config.mjs`: makes backend production code use the logger boundary while allowing the logger itself to own the remaining backend `console.error`.

#### Functions created / updated / deleted

- `normalizeInvite`, `extractInviteFromInput`, `createJoinConfirmationRequest`, `resolveJoinConfirmation`, `extractInviteFromUrl` (`app/invite-confirmation.ts`): created - isolate and test the pending-invite confirmation contract.
- `AppInner` join helpers/effects (`app/index.tsx`): updated - use the helper contract so deep links/manual codes cannot start a join until the user confirms.
- `reserveInviteUse` (`backend/lib/invite-policy.mjs`): created - atomically consume the one allowed invite use before asynchronous BlindPairing work.
- `isInviteUsable` (`backend/lib/invite-policy.mjs`): updated - delegates to the reservation policy for consistent missing/legacy/expired/exhausted handling.
- `createInvite`, `rotateInviteAndNotifyFrontend`, `setupBlindPairing`, `joinViaInvite` (`backend/lib/network.mjs`): updated - enforce one-use/10-minute invites, close rejected candidates, remove the active invite during reserved candidate processing, and restore previous state after failed joins.
- `createJoinRollbackSnapshot`, `restoreJoinRollbackSnapshot`, `cloneBuffer` (`backend/lib/join-rollback.mjs`): created - make rollback copying and restoration testable without a live swarm.
- `deleteLegacyInviteFile` (`backend/lib/key.mjs`): created/renamed from `deleteInvite` - remove stale plaintext invite files without preserving an invite persistence API.
- `deleteInvite` (`backend/lib/key.mjs`): deleted - replaced by legacy cleanup naming.
- `redactForLog`, `redactString`, `parseLogArgs`, `logger.log`, `logger.info`, `logger.warn`, `logger.error`, `isBytes`, `isListItemShape` (`backend/lib/logger.mjs`): created - centralize structured backend log redaction.
- `open`, `apply` (`backend/backend.mjs`), `addItem`, `updateItem`, `deleteItem`, `syncListToFrontend`, `rebuildListFromPersistedOps` (`backend/lib/item.mjs`), and key persistence helpers (`backend/lib/key.mjs`): updated - use the logger boundary and stop logging raw list/key-shaped values.

#### Implementation summary

- Deep links and pasted invite codes now create a pending confirmation instead of immediately joining. Cancel clears only the pending invite; confirm sends the join RPC only if the same invite is still pending.
- Host invites remain in memory, are single-use, expire after 10 minutes, and are reserved before async candidate acceptance so a second candidate cannot reuse the same invite while the first is being processed.
- The old `lista-invite.json`/`invite.json` plaintext invite persistence path is retained only as a legacy cleanup target; no invite material is written there.
- Join failure snapshots the previous visible list and base/encryption keys, then restores them through a tested rollback helper.
- The backend logger boundary was included in the implementation commit because the worktree already depended on it; it also keeps invite/key-shaped data redacted in the new Phase 1 paths. Shared-package logger extraction remains Phase 10.
- Commit range: `ef7b181..ee0dd26` (`ee0dd26` - `Phase 1: invite safety and deep-link confirmation`) on `listam-mobile` branch `phase-0-bootstrap` (not pushed).
- Verification: `npm run test:security` (16 tests pass); `npm run ci` (green: lint 0 errors / 24 grandfathered app console warnings, check:deps OK, check:secrets OK, security tests pass, grocery tests pass); `npm run typecheck` still fails only on the pre-existing generated `itemIconMap.ts` duplicate keys and `_useWorklet.ts` IPC type mismatch already recorded in Phase 0; `npm run bundle:backend:ios`; `npm run bundle:backend:android`; `git diff --check`.

#### Follow-up hardening (commit a585c4a)

A frontend/TS-only follow-up that hardens the invite-safety work without touching the backend or the native Bare bundles, so no runtime artifacts changed:

- `app/invite-confirmation.ts`: added `parseInviteLink` (strict scheme/host parse of incoming deep links) and `planIncomingLinkJoin` (pure link → confirmation decision); added a `confirmation-open` status so a *different* invite arriving while a dialog is open is suppressed instead of stacking a second dialog; the confirmation dialog now names the invite source and adds a warning when a link is not from `listam.ch`/`listam://`.
- `app/index.tsx`: extracted `presentJoinConfirmation` so manual codes and deep links share one thin caller; the deep-link effect now routes through `planIncomingLinkJoin`; removed the two `console.log` calls that Phase 1 had added (no-console warnings 24 → 22).
- `backend/lib/invite-confirmation.test.mjs`: **closes the deep-link wiring test gap** — adds automated coverage for the H2 acceptance cases that previously had none (cold-start link, foreground link, duplicate-link suppression, non-invite URL ignored, untrusted-host warning, busy-while-joining) plus `parseInviteLink` trust/host assertions.
- Verification: `npm run ci` green (lint 0 errors / 22 grandfathered app console warnings, check:deps OK, check:secrets OK, 21 tests pass — up from 16 — grocery tests pass); `npx tsc --noEmit` still fails only on the pre-existing `itemIconMap.ts` duplicate keys and `_useWorklet.ts` IPC mismatch.
- Commit `a585c4a` (`Phase 1 follow-up: test deep-link join wiring and harden link confirmation`) on `listam-mobile` branch `phase-0-bootstrap` (not pushed). Full Phase 1 range: `ef7b181..a585c4a`.

#### Follow-up risks / blockers

- The invite is still a writer-access BlindPairing capability until Phase 3 membership authority and Phase 4 re-keying land; true member removal is not solved in Phase 1.
- **Deferred by decision:** user-facing invite revoke/rotate controls and a live lifetime/use-count display (H3's full UI scope) are deferred to a dedicated invite-lifecycle phase rather than expanding Phase 1. The auto-rotation behavior (a fresh single-use invite is minted after each accept) is kept as-is by decision.
- App-side `console` warnings remain in `_useWorklet.ts` and `useSubscription.ts`; the two Phase 1-added calls in `app/index.tsx` were removed in `a585c4a`, and backend console use is behind the redacting logger boundary.
- The generated backend bundles remain committed runtime artifacts from `ee0dd26`; the follow-up did not regenerate them because it is frontend/TS-only, and the larger generated Metro/Android bundles remain outside this phase.
- Pre-existing `typecheck` failures remain and should be handled in their own change before promoting typecheck into CI.

</details>

<details>
<summary>Phase 2 - Secret-storage foundation (key material)</summary>

Commit boundary: introduce the platform secure-storage boundary in mobile (later extracted to `@listam/secrets`); migrate existing plaintext key material (`lista-encryption-key.txt`, the autobase key, writer and pairing secrets) into secure storage; store fingerprints only in metadata/logs; pass secrets to the backend through the platform adapter instead of long-lived plaintext files; provide a recovery path when secure storage is unavailable.

Rationale: this precedes the membership-crypto work because Phases 3-4 create new long-lived key material (the owner authority key and per-epoch encryption keys) that must be born in secure storage rather than retrofitted.

Depends on: 0. Unblocks: 3, 4, 10.

Acceptance: no plaintext key files remain after migration and the backend boots from adapter-passed secrets. Rollback: migration is idempotent and re-readable; an abort restores from the pre-migration plaintext until deletion is confirmed.

Pause gate: commit the secret-storage foundation, record the modified files/functions, and wait before membership authority.

</details>

<details>
<summary>Phase 3 - Membership authority and honest revocation language (C3, C1 language)</summary>

Commit boundary: rename revoke semantics to "revoke invite," introduce owner-signed membership records, reject non-owner writer additions, store the owner authority key via the Phase 2 secrets boundary, and document that true member removal requires re-keying.

Depends on: 2. Unblocks: 4.

Acceptance: a non-owner writer cannot add another writer; legacy single-user bases migrate once without losing the existing owner device. Rollback: a tightly scoped legacy migration window; malformed, unsigned, or replayed membership ops are rejected.

Pause gate: commit the membership authority work, record the modified files/functions, and wait before implementing key epochs.

</details>

<details>
<summary>Phase 4 - Key epochs and member-removal re-key flow (C1)</summary>

Commit boundary: add app-level membership epochs, encryption-key rotation/re-encryption with epoch keys stored via the secrets boundary, old-epoch retirement, member-removal audit events, and rollback tests for interrupted re-key.

Depends on: 3. Unblocks: -. (End of the membership-crypto track.)

Acceptance: a removed device can no longer decrypt or append in the new epoch. Rollback: an interrupted re-key restores the prior epoch read-write and never leaves the base unreadable.

Pause gate: commit the re-key flow, record the modified files/functions, and wait before the desktop/headless build (this track reconverges with the data-model track at Phase 11).

</details>

<details>
<summary>Phase 5 - Stable item IDs and backend reduction migration (M1)</summary>

Commit boundary: version list operations, backfill ids for legacy text-only entries, reduce by id when present, keep legacy compatibility, and prove duplicate-name convergence.

Depends on: 0. Independent of the 2-4 membership-crypto track and may run in parallel with it. Unblocks: 6.

Acceptance: the backend materialized view and Redux projection agree on duplicate names; legacy text-only lists migrate without losing done state or order. Rollback: mixed legacy/new operation logs replay correctly.

Pause gate: commit the id migration, record the modified files/functions, and wait before the Redux migration.

</details>

<details>
<summary>Phase 6 - Redux Toolkit migration in mobile, in place</summary>

Commit boundary: add the Redux Toolkit store and move list, sync, preferences, locale choice, loyalty-card metadata handles, and owned-devices state into slices normalized by id; replace direct `useState` ownership of replicated list data with selectors and actions; keep existing mobile behavior intact. No package extraction yet.

Depends on: 5. Unblocks: 7.

Acceptance: mobile parity is unchanged with replicated state owned by Redux; the `loyaltyCards` slice holds only non-secret handles (M3), never barcode/QR payloads.

Pause gate: commit the in-place Redux migration, record the modified files/functions, and wait before package extraction.

</details>

<details>
<summary>Phase 7 - Extract pure shared packages</summary>

Commit boundary: extract `@listam/domain`, `@listam/protocol`, `@listam/grocery`, `@listam/logging` (including redaction helpers and the log line format), and `@listam/secrets` (the Phase 2 boundary) as versioned packages; mobile consumes them; behavior intact.

Depends on: 2, 6. Unblocks: 8, 9, 10.

Acceptance: mobile builds against published package versions and the shared suites run in Node.

Pause gate: commit the pure-package extraction, record the modified files/functions, and wait before the backend/client extraction.

</details>

<details>
<summary>Phase 8 - Extract backend/client with platform adapter</summary>

Commit boundary: extract `@listam/backend` and `@listam/client`; decouple the backend from BareKit globals (`BareKit.IPC`, `Bare.argv`, `Bare.on('teardown')`) behind a platform-services adapter so it runs under the mobile worklet and Node; keep per-platform `bare-pack` bundling an app-level build step.

Depends on: 7. Unblocks: 11, 12, 13.

Acceptance: the backend runs under Node with no BareKit globals, and the same `@listam/client` contract suite passes on both the worklet and Node adapters.

Pause gate: commit the backend/client extraction, record the modified files/functions, and wait before recovery/durability changes.

</details>

<details>
<summary>Phase 9 - UI internationalization foundation</summary>

Commit boundary: add shared UI i18n infrastructure (`@listam/i18n` or the equivalent shared module), typed message catalogs, locale detection/override in preferences, fallback behavior, plural/date/number formatting helpers, pseudo-locale utilities, and mobile UI string extraction for the parity surfaces. Keep grocery category/item translations in `@listam/grocery`, but route them through the same selected-locale resolver.

Depends on: 6, 7. Unblocks: 12, 15.

Acceptance: user-facing mobile UI copy is routed through typed message keys; English plus at least one non-English catalog render; missing keys fail CI; pseudo-locale/long-string checks pass for the main list, invite/join confirmation, settings/preferences, diagnostics, and loyalty-card surfaces. Rollback: language preference falls back to system/default locale without corrupting local preferences.

Pause gate: commit the UI internationalization foundation, record the modified files/functions, and wait before redaction/durability or desktop implementation.

</details>

<details>
<summary>Phase 10 - Loyalty-card secrets and redaction routing (M3, M5)</summary>

Commit boundary: move loyalty-card barcode/QR payloads into secure storage via the Phase 2 boundary, keep only non-secret handles in the Redux slice, route all logging through `@listam/logging` redaction, and add export/diagnostic redaction tests.

Depends on: 2, 6, 7. Unblocks: 11.

Acceptance: Redux state, DevTools-style traces, and exports never contain card payloads or raw secrets. Rollback: the AsyncStorage-to-secure-storage card migration is idempotent.

Pause gate: commit the loyalty-card/redaction work, record the modified files/functions, and wait before recovery/durability changes.

</details>

<details>
<summary>Phase 11 - Recovery, snapshots, and storage durability (M4)</summary>

Commit boundary: replace destructive auto-wipe recovery with backup/quarantine/owner-confirmed recovery, add materialized-view snapshots/checkpoints that resume the id-keyed reduction, isolate storage roots, and add a real lock/lease with stale-lock recovery for multiple processes on one machine.

Depends on: 5 (the checkpoint sits on the id-keyed reduction), 8, 10. Unblocks: 12, 13.

Acceptance: a corrupt Autobase/Corestore state never triggers silent deletion, headless nodes refuse auto-wipe, and the rebuild resumes from a checkpoint with bounded join-poll work.

Pause gate: commit the durability work, record the modified files/functions, and wait before desktop implementation.

</details>

<details>
<summary>Phase 12 - Desktop parity surface</summary>

Commit boundary: build the Pear Desktop app around the shared packages, match current mobile parity, implement desktop IPC/client contracts, consume the Phase 9 UI catalogs, and compare UI against `listam-desktop/design-guide/`. The desktop owner-control client is deferred to Phase 14.

Depends on: 8, 9, 11. Unblocks: 15.

Acceptance: desktop reaches mobile parity, syncs with mobile through invite, uses the shared UI i18n catalogs, and matches the desktop design-guide examples in English and pseudo-localized/long-string modes.

Pause gate: commit the desktop parity work, record the modified files/functions, and wait before headless implementation.

</details>

<details>
<summary>Phase 13 - Headless service and CLI parity (C2)</summary>

Commit boundary: build the Pear Terminal/Bare headless app as a long-lived owned peer, persist the data model, add CLI setup/status/invite/join/export/shutdown commands, enforce blind-helper credential boundaries (a blind helper never receives the encryption key), and add resource quotas on queues and storage. The owner-control protocol is Phase 14.

Depends on: 8, 11. Unblocks: 14, 15.

Acceptance: a blind-storage instance replicates but cannot decrypt `view.get()`; a restart preserves identity, storage, and status.

Pause gate: commit the headless service work, record the modified files/functions, and wait before the owner-control protocol.

</details>

<details>
<summary>Phase 14 - Owner-control protocol (H1)</summary>

Commit boundary: establish per-device key pairs at pairing; require every command to carry a nonce/timestamp for replay protection and a signature; model capabilities as separate grants (`status:read`, `diagnostics:read`, `topics:configure`, `invite:create`, `export:create`, `import:apply`, `service:shutdown`); add device revocation and key rotation; build the desktop and mobile owner-control clients.

Depends on: 13. Unblocks: 15.

Acceptance: headless refuses unsigned, replayed, expired, or out-of-scope commands, and a diagnostics-only client cannot shutdown, import, export, or configure topics.

Pause gate: commit the owner-control protocol, record the modified files/functions, and wait before full cross-app acceptance.

</details>

<details>
<summary>Phase 15 - Cross-app acceptance matrix and release readiness</summary>

Commit boundary: automate the private-bootstrap cross-instance matrix, prove mobile/desktop/headless convergence, run the cumulative-migration chain on one base (id-backfill, then owner-key adoption, then epoch, then secret-store) to prove stacked migrations are forward-compatible, document manual acceptance, and close first-milestone release risks.

Depends on: 12, 14. Unblocks: -.

Acceptance: the headless-driven subset of the matrix runs in CI, the cumulative-migration chain passes, and each capability is "done" only when its matrix row passes.

Pause gate: commit the acceptance work, record the modified files/functions, and pause for milestone review before adding new list domains.

</details>
