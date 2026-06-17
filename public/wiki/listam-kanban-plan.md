# Kanban boards with rigor mode, time tracking & congruency

## Context

listam today is a P2P grocery/list app: every item is a flat `{id, text, isDone,
timeOfCompletion, updatedAt, listId, listType}` record replicated over Autobase.
We mocked (in this session) a full kanban experience — a project/ticket board,
two ticket-detail views, and a Properties/States/Automations/Rules config — and
now want to implement it.

The new product rules:

1. **Rigor mode** — a board-level mode, **on by default**, that the board owner can
   disable. While on, creating a ticket requires at minimum: a short description, a
   task checklist (≥1), estimated hours (>0), and estimated complexity (1–100%).
2. **Time tracking** — accumulate the time a ticket spends in the *In Progress* state.
3. **On-time flagging** — on reaching *Done*, freeze a verdict from
   `delta = (actualInProgressHours − estimatedHours) / estimatedHours`:
   `delta > +10%` → **overtime** (not in time); `delta < −10%` → **undertime**
   (overestimated); otherwise **on time**.
4. **Congruency score** (per user) — calibration accuracy: a user is more congruent
   the closer their average estimated complexity is to the share of their tickets
   that missed the estimate (ran overtime **or** undertime).

**Authority model (user decision):** the **signature of the board creator** is the
authority. Rigor mode and all board configuration are stored as an **owner-signed
record** verified against the creator's authority key — no client (desktop, mobile,
headless, leaf) can change them without that signature. This reuses the proven
`membership.mjs` owner-signed-record pattern.

**Outcome:** a kanban board where tickets are first-class items, estimation
discipline is enforceable and creator-controlled, delivery accuracy is measured
objectively, and every peer agrees on the numbers.

---

## Load-bearing architecture (verified against source)

- **Tickets are list items.** `normalizeListItem` (`listam-packages/packages/domain/list-reducer.mjs:17`)
  spreads `...item` before stamping the three required fields (`text`, `isDone`,
  `timeOfCompletion`), so **arbitrary extra fields survive the reduction untouched**.
  A ticket is a list item with `listType:'kanban'` + extra optional fields. No new op
  types, and **no `LIST_OPERATION_VERSION` bump** (stays `1`; ops with `version>1` are
  dropped — keep it 1 for forward-compat with old peers).
- **`RPC_UPDATE` already passes extra fields through** (`item.mjs:156` spreads `...item`),
  but **`addItem(text, listId, listType)` discards everything but `text`** (`item.mjs:98`).
  → `addItem` and the `RPC_ADD` handler must be extended to carry ticket fields. This is
  the one unavoidable backend change for ticket creation.
- **LWW on `updatedAt`.** `isStaleUpdate` (`identity.mjs`) drops any update with a lower
  `updatedAt`. **Every** ticket mutation (drag, block edit, checklist toggle, property
  edit) MUST set `updatedAt: Date.now()`. Forgetting this is the #1 silent-no-op bug.
- **Owner-signed shared state precedent:** `membership.mjs` — `ownerAuthorityKeyPair`,
  owner check `canCreateMembershipInvite(state, ownerAuthorityKeyPair)`, records persisted
  to the view as `{op:'membership', record}`, rebuilt via `reduceMembershipLog` +
  `view-checkpoint.mjs` (returns `{items, membershipRecords}`), and `normalizeViewEntry`
  ignores `op:'membership'` (`list-reducer.mjs:158`) so control records never pollute the
  item reduction. Board config will mirror this exactly.
- **New `RPC_MESSAGE` types need no client change** — the client adapter forwards unknown
  `{type}` payloads as a generic event.
- **Writes are serialized** through `enqueueWrite` and gated by `waitForFlushableWriter`
  (`item.mjs:72,31`) — reuse, don't bypass.

---

## Data model — ticket fields (all optional; absence = legacy/non-rigor)

Added to `NormalizedListItem` typing in `listam-packages/packages/domain/list-reducer.d.ts`
(declared as an exported `KanbanFields`; carried via the existing catch-all at runtime):

| Field | Type | Notes |
|---|---|---|
| `status` | `'todo'\|'in_progress'\|'blocked'\|'review'\|'done'` | board column. Keep `isDone = (status==='done')` so legacy UIs still read done-ness. |
| `description` | `string` | rigor-required (short description). |
| `checklist` | `{id,text,done}[]` | rigor-required (≥1). |
| `estimatedHours` | `number` | rigor-required (>0). |
| `estimatedComplexity` | `number` (1–100) | rigor-required. |
| `priority` | `'low'\|'medium'\|'high'\|'urgent'` | optional. |
| `assignee` | `string` (writer-key hex) | optional. |
| `createdBy` / `completedBy` | `string` (writer-key hex) | attribution, stamped write-side. |
| `inProgressMs` | `number` | cumulative accumulator. |
| `inProgressSince` | `number\|null` | wall-clock ms of current in-progress entry. |
| `actualInProgressHours` | `number` | frozen at Done. |
| `timeliness` | `'on_time'\|'overtime'\|'undertime'` | frozen at Done. |
| `blocks` | `Block[]` | block-based body (see below). |
| `kanbanVersion` | `number` (=1) | field-level marker, independent of op version. |

`Block = {id, type, ...payload}`, `type ∈ {markdown, image, table, links, checklist,
numberedList, callout, code}`.

---

## Board configuration — one owner-signed record (creator authority)

New module **`listam-packages/packages/backend/lib/board-config.mjs`** (models `membership.mjs`).
A single owner-signed record holds the whole board config (this is also what the
Properties/States/Automations/Rules mock edits):

```
{ type:'board-config', version:1, sequence, ownerAuthorityKey, createdAt,
  rigorOn: true,                       // default ON
  states:     [{id,name,color,wipLimit,isDone}],   // board columns
  properties: [{key,label,kind,options}],          // ticket fields/property rail
  rules:      [{id,kind,params,enforce:'block'|'warn'}],   // WIP, required-owner, done-gate, blocked-reason, rigor-required
  automations:[{id,trigger,actions,enabled}],      // on-done→freeze timeliness/archive, urgent→notify, etc.
  signature }
```

- `createBoardConfigState()` → defaults (`rigorOn:true`, the 4 default states, built-in
  rules/automations). Absence of any record = defaults (rigor ON).
- `createBoardConfigRecord({ownerAuthorityKeyPair, baseKey, config, sequence, createdAt})` —
  signs the canonical body with the creator's authority secret (same canonicalization as
  `membershipSigningPayload`).
- `reduceBoardConfigOperation(record, state, {baseKey, ownerAuthorityKey})` — `verify`
  against `body.ownerAuthorityKey`; accept only if it equals the membership's
  `ownerAuthorityKey` (the **board creator**); reject wrong-base / replay (`sequence ≤
  highest`) / bad-signature. **This is how non-creators are prevented — purely
  cryptographic, no client trust.**
- `reduceBoardConfigLog(records, opts)` — rebuild after restart.
- `isBoardConfigRecord(value)`.

**Wiring:**
- `apply()` (`backend.mjs`): after the membership branch, handle `isBoardConfigRecord(value)`
  → reduce, `setBoardConfigState`, persist `{op:'board-config', record}`, broadcast.
- `view-checkpoint.mjs`: collect `entry.op === 'board-config'` into a `boardConfigRecords[]`
  (alongside `membershipRecords`), keep it out of the item reduction (add the guard in
  `normalizeViewEntry` like `op:'membership'`).
- `state.mjs`: add `boardConfigState` + setter (default config), rebuilt on restart via a
  new `readPersistedBoardConfigRecords()` in `item.mjs` (mirrors `readPersistedMembershipRecords`).
- Owner-only mutation RPC (below); non-owner attempts → `notifyFrontend({type:'config-denied',reason:'not-owner'})`.

---

## Shared domain logic — `listam-packages/packages/domain/kanban.mjs` (NEW, pure)

Single source of truth, callable by backend AND any frontend, fully unit-testable:

- `DEFAULT_BOARD_CONFIG`.
- `validateTicketDraft(item, config)` → `{ok, missing[]}`. When `config.rigorOn`, requires
  description, checklist≥1, estimatedHours>0, estimatedComplexity∈[1,100]. Enforced on
  **add** only (never on update, so status changes of legacy/grandfathered tickets are
  never rejected).
- `applyStatusTransition(existing, incoming, now)` → mutated fields. On entering
  `in_progress`: set `inProgressSince=now`. On leaving: `inProgressMs += max(0, now −
  inProgressSince)` (clamp negative skew; cap a single slice to bound garbage), clear
  `inProgressSince`. On entering `done`: flush the open slice, set
  `actualInProgressHours = inProgressMs/3.6e6`, compute `delta`, freeze `timeliness`,
  set `isDone:true`, `timeOfCompletion:now`, `completedBy`. Reopen (`done→in_progress`)
  re-arms; re-completion recomputes.
- `computeCongruency(tickets)` → per-user stats grouped by `completedBy ?? createdBy`:
  - `N` = completed count; `avgComplexityPct` = mean(`estimatedComplexity`);
    `offEstimateRatePct` = 100·(#overtime + #undertime)/N  — the share that missed the
    estimate in **either** direction (i.e. `100 − onTimeRate`).
  - `gap = |avgComplexityPct − offEstimateRatePct|`; `raw = 100 − gap`.
  - **Volume shrinkage** toward neutral 50: `score = round(50 + (raw − 50)·N/(N+5))`.
  - Also emit `onTime/over/under` counts and an optional `tendency`
    (`underestimates|overestimates|calibrated`, from #overtime vs #undertime) for display.
- `evaluateRules(config, nextItem, prevItem)` → `{blocked[], warnings[]}` (WIP limit,
  required-owner-in-active, done-gate "no open checklist items", blocked-needs-reason).

**Timeliness/time are frozen at the source writer** (in `applyStatusTransition`, called by
`updateItem`) — only the writer that owns the wall clock computes its own elapsed slice;
every peer then receives the frozen verdict verbatim and agrees. Cross-writer clock skew
is clamped; concurrent in-progress exits can lose one increment under LWW (documented
limitation, acceptable — no counter-CRDT).

---

## Backend changes (summary)

`listam-packages/packages/`:

- **`protocol/index.mjs` (+`.d.ts`)** — add `RPC_SET_BOARD_CONFIG = 22`,
  `RPC_GET_BOARD_CONFIG = 23`. (Ticket CRUD reuses `RPC_ADD/UPDATE/DELETE`.) Bump package version.
- **`backend/lib/item.mjs`**:
  - Extend `addItem` to accept optional ticket fields (merge onto the constructed item;
    stamp `createdBy = autobase.local.key.toString('hex')`, `status` default `todo`).
  - In `updateItem`, diff incoming vs `currentList` status and run
    `applyStatusTransition` (time accumulation + timeliness freeze + `completedBy`).
  - `readPersistedBoardConfigRecords()`.
- **`backend/lib/board-config.mjs`** (NEW) — owner-signed config (above).
- **`backend/backend.mjs`** — `apply()` board-config branch + rigor add-gate
  (read reduced `boardConfigState.rigorOn`; **fail OPEN** when indeterminate so a write is
  never permanently dropped); `RPC_SET_BOARD_CONFIG` handler guarded by
  `canCreateMembershipInvite(membershipState, ownerAuthorityKeyPair)`; `RPC_GET_BOARD_CONFIG`.
- **`backend/lib/view-checkpoint.mjs`** — collect `op:'board-config'` records.
- **`domain/kanban.mjs`** (NEW), **`domain/list-reducer.d.ts`** (types),
  **`domain/identity`** (no change).
- **Attribution caveat:** `createdBy/completedBy/assignee` are self-asserted (honest-client).
  The rigor *rule* is signature-enforced; per-ticket attribution is not. Upgrade path if
  non-repudiation is later needed: derive from `node.from` in `apply()` (currently discarded).

---

## Desktop UI changes — `listam-desktop/src/`

New pure module **`src/ticket.mjs`** (selectors/helpers; keeps `ui.mjs` presentational and
re-exports the shared `@listam/domain/kanban` math): `isTicket`, `isKanbanList`,
`groupByStatus(items, states)`, `ticketBadges(item, now)`, `selectBoardConfig(state)`,
`selectWriterStats(items)` (delegates to `computeCongruency`), `validateRigorDraft`.

**`src/ui.mjs`:**
- `ui` object: add `view` values `'board'|'congruency'`, plus `selectedTicketId`,
  `ticketDocId`, `boardDrag`, `blockEditingId` (UI-local, **not** store state — keeps drag
  off the re-render path).
- `RAIL_DEFS`: add `{key:'board', icon:'layout-columns', …}`; badge = in-progress count.
  `SYSTEM_DEFS`: add `{key:'congruency', icon:'gauge', …}`.
- `renderMain` dispatch: `if (ui.ticketDocId) renderTicketFull`; `if view==='board'
  renderBoardPane`; `if view==='congruency' renderCongruencyPane`.
- `renderBoardPane` → columns from `groupByStatus`; `renderBoardColumn`; `renderTicketCard`
  (priority pill, assignee avatar, due, checklist count, **in-progress timer**, **on-time/
  overtime/undertime badge** when done). Reuse `rowAnimationClass` but **suppress while
  `ui.boardDrag` is set**.
- Detail: three shared pure builders used by BOTH presentations (no duplication):
  `renderTicketSummary`, `renderTicketBody` (block renderer), `renderPropertyRail`
  (Shared-with pinned top, then properties). `renderTicketSplitPanel` (right aside, board
  shrinks to `1fr 420px`) and `renderTicketFull` (full-canvas `.ticket-doc` grid) compose them.
- **Block editor** (`renderTicketBody`): `BLOCK_RENDERERS` dispatch for the 8 types; hover
  `.block-gutter` with `+`/drag handle; `/` opens `.block-slash-menu`; all edits persist via
  one `commitBlocks(item, next)` → `RPC_UPDATE` with `updatedAt`. Live markdown = minimal
  subset (bold/italic/`code`/links) rendered from a `<textarea>` on blur — **no full WYSIWYG**.
- **Rigor create dialog** (`kind:'add-ticket-rigor'` via `dialogFrame`): description input,
  task-checklist rows (add/remove), `number` hours, complexity `range` slider with live %.
  `validateRigorDraft` on submit → `.shake` missing fields + a `.rigor-notice` listing them;
  keep draft in `ui.dialog.draft` so peer re-renders don't wipe it. Rigor OFF → quick
  single-field add via the existing add-bar but stamped `listType:'kanban'`.
- **Settings rigor/config row** (extend `kind:'settings'`): if `roster.canAdminister`
  (creator) → interactive toggle that sends `RPC_SET_BOARD_CONFIG`; else read-only chip +
  "only the board owner can change this".
- **Board config dialog** (the Properties/States/Automations/Rules tabs mock) →
  `kind:'board-config'`, owner-gated, writes `RPC_SET_BOARD_CONFIG`.
- `renderCongruencyPane` → one `.congruency-card` per user: completed count, on-time/over/
  under breakdown bar, score numeral + reason, optional tendency.
- Drag-and-drop: **native HTML5 DnD** (survives full re-render); all feedback via direct
  `classList` (never `renderAll` mid-drag); single `RPC_UPDATE` on drop; keyboard fallback
  (`Ctrl+←/→`) for a11y.

**`src/store.mjs`:** board/rigor/stats all **derive from `state.items`** (no duplicated
ticket state). Add `applyClientEvent` cases for `board-config` (from `RPC_GET/SET` →
`state.boardConfig`) and `config-denied` (notice). Add one local pref
`boardColumnOrder:{}` in `DEFAULT_PREFERENCES`.

**`app.css`:** new classes reusing existing tokens (flat, hairline, acid `--signal`):
`.kanban-board/.kanban-column/.kanban-col-head/.ticket-card/.priority-pill/.avatar/
.time-in-progress/.on-time-badge/.over-badge/.detail-split/.ticket-doc/.prop-rail/.block/
.block-gutter/.block-slash-menu/.rigor-checklist/.complexity-slider/.rigor-notice/
.congruency-card/.congruency-bar/.congruency-score`.

**`src/tabler-icons.mjs`:** add `layout-columns, grip-vertical, flag, clock, gauge,
calendar, photo, table, link, code, quote, list-numbers, share` (others exist).

**`@listam/i18n` catalogs:** add all new keys to **all 6 catalogs** (en/es/de/fr/it/pt) —
`assertCompleteCatalog` parity test fails otherwise.

---

## Mockups (in chat) + implementation mapping

Existing (rendered earlier this session):
1. **Kanban board** → `renderBoardPane`/`renderBoardColumn`/`renderTicketCard`; columns from
   `groupByStatus(items, config.states)`.
2. **Board config (Properties/States/Automations/Rules)** → `kind:'board-config'` dialog;
   persisted in the owner-signed `board-config` record; owner-gated.
3. **Ticket split panel** → `renderTicketSplitPanel` (+ shared builders); opens on card click;
   `⤢` promotes to full view.
4. **Ticket full screen** (Shared-with pinned top of rail) → `renderTicketFull`; same builders.

New (rendered alongside this plan):
5. **Rigor create form** → the `add-ticket-rigor` dialog + `validateRigorDraft`.
6. **Congruency dashboard** → `renderCongruencyPane` + `computeCongruency` (calibration gap).
7. **Ticket card timeliness states** → `ticketBadges`: in-progress timer + on-time/overtime/
   undertime badges, driven by frozen `timeliness`/`inProgressMs`.

---

## Other good / important additions

- **Activity feed**: persist `{op:'activity'}` entries (ticket completed + timeliness,
  config changed) and surface in the existing Activity nav.
- **Reopen handling**: `done→in_progress` re-arms timing; re-completion recomputes timeliness.
- **Settings item filtering**: ensure control records and the grocery list never render
  kanban tickets and vice-versa (filter by `listType`).
- **Mock fixtures**: extend `mock-backend.mjs` seed with kanban tickets (mixed statuses,
  some done with each timeliness) + a board-config so `?mock=1` exercises board/rigor/
  congruency without a backend.
- **Accessibility & reduced motion**: keyboard drag, focus management on panel open/close,
  honor `prefers-reduced-motion`.
- **Back-compat**: no op-version bump; optional fields; default config when no record;
  old peers ignore unknown fields and re-emit them intact.
- **Mobile/headless parity**: same shared `@listam/domain/kanban` logic; UI is a follow-up
  (post-parity milestone) but the data + rules already hold cluster-wide via the signed config.

---

## Testing

`node:test`, `npm test`, colocated `*.test.mjs`:

- `domain/kanban.test.mjs` — `validateTicketDraft` (rigor on/off, bounds), `applyStatusTransition`
  (entry/exit accumulation, clamp, done freeze, reopen+re-done, cross-writer cap),
  `computeCongruency` (gap math, shrinkage at low N, tendency, empty/zero guards),
  `evaluateRules`.
- `backend/lib/board-config.test.mjs` — default rigor ON; valid creator record flips it;
  non-creator signature rejected; replay rejected; `reduceBoardConfigLog` rebuild; wrong-base.
- `backend` apply integration — non-rigor kanban add dropped when rigor ON / accepted when OFF;
  config records persist + survive checkpoint reset; checkpoint keeps `op:'board-config'` out
  of item reduction.
- `domain/list-reducer.test.mjs` (extend) — kanban item w/ extra fields round-trips unchanged;
  `version>1` still dropped.
- desktop `test/ticket.test.mjs` — `groupByStatus`, `validateRigorDraft`, drop-payload shape
  (done sets isDone/timeOfCompletion/timeliness; same-status = no-op), congruency rendering math.
- desktop `test/store.test.mjs` (extend) — kanban ticket + `board-config` event reductions;
  stale-update ignored.
- i18n parity test (existing) gates the 6-catalog key additions.

## Verification (end-to-end)

1. `npm test` in `listam-packages` and `listam-desktop` (all green, incl. i18n parity).
2. Launch desktop with `?mock=1` (Pear dev): create a board, add a ticket with rigor ON
   (confirm required-field validation + shake), drag through columns, watch the in-progress
   timer, send one to Done and confirm the frozen on-time/overtime/undertime badge, open the
   congruency dashboard and confirm the calibration-gap score.
3. Two-peer cross-device run (`tools/cross-device` harness, Pi/Geekom peers): (a) creator
   toggles rigor OFF → propagates; (b) **non-creator** attempt to toggle is rejected
   (signature) → stays unchanged on all peers; (c) a non-rigor ticket add by a hacked client
   is dropped cluster-wide when rigor ON; (d) a ticket completed on peer A shows the **same**
   timeliness verdict on peer B.

## Critical files

- `listam-packages/packages/protocol/index.mjs` (+`.d.ts`)
- `listam-packages/packages/domain/kanban.mjs` (NEW), `list-reducer.d.ts`
- `listam-packages/packages/backend/lib/board-config.mjs` (NEW), `item.mjs`,
  `view-checkpoint.mjs`, `state.mjs`
- `listam-packages/packages/backend/backend.mjs` (`apply()` + RPC handlers)
- `listam-desktop/src/ticket.mjs` (NEW), `ui.mjs`, `store.mjs`, `app.css`,
  `tabler-icons.mjs`, `mock-backend.mjs`, `test/ticket.test.mjs` (NEW)
- `listam-packages/packages/i18n/catalogs/{en,es,de,fr,it,pt}.mjs`

## Suggested build order (single milestone, sequenced to de-risk)

1. `domain/kanban.mjs` + tests (pure, no UI/backend).
2. `board-config.mjs` + tests; protocol constants; `apply()`/checkpoint/state wiring.
3. `item.mjs` add-fields + time/timeliness; backend apply gate; integration tests.
4. Desktop: icons + i18n; `ticket.mjs`; `app.css`; board view (read-only) → DnD → detail
   (split + full) → block editor → rigor dialog → settings/board-config (owner-gated) →
   congruency pane.
5. Mock fixtures; manual + two-peer verification.

---

# Mobile implementation plan — multiple typed lists + groups + swipe nav + kanban

## Context
The desktop kanban feature (above) is shipped and tested, and the mobile mockups are
approved (monochrome + green `#2f9e44`, native to `listam-mobile/app/theme.ts`). This
phase brings it to the mobile app (Expo/React-Native + Redux Toolkit, single-screen,
`listam-mobile/`): the user organizes typed lists (grocery + kanban) into **groups**,
flags one list **default** (app opens there), and navigates by **swiping** between lists
(crossing a group boundary raises a toast; long-press an empty area + swipe jumps a
group); kanban lists get a board, ticket detail, rigor create, time tracking, on-time
flagging and congruency — all reusing the shared `@listam/domain/kanban`.

User decisions (2026-06-15): list organization (groups/order/membership) **syncs across
the project**; the **default list is per-device**; gesture model = **flip grocery
swipe-to-delete to swipe-LEFT + switch kanban columns by tapping** (horizontal swipe is
reserved for list nav).

## Key architecture decisions
- **Synced list registry via reserved meta-items (no new backend).** List + group
  metadata are stored as ordinary synced items in a reserved meta list (`listType:
  'registry'`): each carries `{ kind:'list'|'group', name, type?, groupId?, order }` plus
  the base item fields. They flow through the EXISTING `RPC_ADD/UPDATE/DELETE` → sync →
  reduce pipeline (LWW via `updatedAt`, epoch-encrypted, attributed) with **zero backend
  changes**. Frontends reduce them into a registry and filter `listType:'registry'` out of
  user-facing views (the codebase already filters by `listType`). Fallback if this proves
  too implicit: a dedicated owner-signed `list-registry` record mirroring
  `backend/lib/board-config.mjs` (heavier — protocol const + apply branch + checkpoint).
- **Default list is local** (`preferencesSlice` + AsyncStorage) — "opens here on launch"
  is inherently per-device.
- **Pager built on RN `PanResponder` (capture-phase) + `Animated` translateX** — no new
  deps (no `react-native-gesture-handler`/`react-native-pager-view`; `check-deps.mjs`
  gates new imports). Content swaps by dispatching `selectedListChanged`; the existing
  `selectSelectedListItems` selector re-renders. `react-native-reanimated@4.1` (installed,
  unused) stays optional.
- **Pure reuse of `@listam/domain/kanban`** — port `listam-desktop/src/ticket.mjs` →
  `listam-mobile/app/components/kanban/ticket.ts` (drop the DOM/`innerHTML` markdown bits);
  keep `groupByStatus`/`ticketBadges`/`buildStatusChange`/`validateRigorDraft`/
  `selectWriterStats`/`formatDuration`/`deltaPercent` + block helpers verbatim.

## Shared/domain (small)
- NEW `listam-packages/packages/domain/list-registry.mjs` (+ `.d.ts`, `.test.mjs`, `./list-registry`
  export): pure `reduceRegistry(metaItems) -> { groups:[{id,name,order}], lists:[{id,name,type,groupId,order}] }`
  (LWW by `updatedAt`, deletes via `isDone`/tombstone, stable sort by `order` then name,
  unfiled lists → an implicit "Ungrouped" group last). Used by mobile now and desktop later.
  `REGISTRY_LIST_TYPE='registry'`. No backend changes (rides item ops).

## Mobile state (`listam-mobile/app/store/`)
- NEW `boardConfigSlice.ts`: `{ config, canAdminister }`; `boardConfigReceived`/`boardConfigReset`;
  `selectBoardConfig` (falls back to `normalizeBoardConfig(null)` — never null), `selectBoardConfigCanAdminister`.
- NEW `listRegistrySlice.ts` (DERIVED from synced registry meta-items + local default):
  holds the reduced `{ groups, lists }` (recomputed when registry meta-items change) and is
  fed by a decoder case; plus thunks `createListThunk({name,type,groupId})`,
  `setGroupThunk`, `reorderThunk`, `renameThunk`, `deleteListThunk` that send
  `RPC_ADD/UPDATE/DELETE` for the meta-items. Selectors: `selectGroupedLists`,
  `selectListsInGroup`, `selectListIndexInGroup`. (The registry meta-items themselves land
  in `listsSlice` like any item; this slice projects them — or compute via a memoized
  selector over `listsSlice` + `@listam/domain/list-registry`.)
- `preferencesSlice.ts`: add `defaultListId` (+ AsyncStorage key, hydration, setter) — local.
- `store.ts`: register `boardConfig` (+ `listRegistry` if a slice, else selector-only).
- `app/hooks/_useWorklet.ts` decoder (`case 'message'` chain ~L200-337): add
  `board-config` → `boardConfigReceived`, `config-denied` → snackbar; reset both in `case 'reset'`;
  import + re-export `RPC_GET_BOARD_CONFIG`/`RPC_SET_BOARD_CONFIG`. Registry meta-items
  arrive through the existing `sync-list`/`*-from-backend` cases (no new transport).

## Navigation + gesture layer (`listam-mobile/app/`)
- NEW `app/nav/listNav.ts` (pure, unit-testable): `step(lib,curId,dir,{jumpGroup,wrap})`,
  `nextList`/`prevList`, `crossesGroupBoundary` (→ toast group name),
  `resolveLaunchList(lib, validIds)` (default → first-of-first-group → null; stale default
  falls through). Operates on a `NavLibrary` assembled from `selectGroupedLists`.
- NEW `app/nav/useListPager.ts`: wires selectors + `step` + `dispatch(selectedListChanged)`
  + `useSnackbar().show(toast)` + `expo-haptics`; exposes `{ position, commit(dir,jumpGroup) }`.
  No wrap by default (rubber-band at library edges).
- NEW `app/components/ListSwipePager.tsx`: capture-phase `PanResponder`
  (`onMoveShouldSetPanResponderCapture`) claims horizontal ONLY when clearly horizontal
  (dead-zone ~14px + axis-lock `|dx|>|dy|*1.5`) AND no category drag active
  (`useCategoryDrag().draggingId === null`) AND not in a no-pager zone; animates one
  `Animated.Value` translateX, dispatches on settle; long-press blank area (~250ms, still
  finger) arms `jumpGroup` + haptic; reduced-motion → instant swap. Renders the current
  list view (`InertialElasticList`/`VisualGridList`) as children — wraps `index.tsx` L812-839.
- NEW `app/components/PositionIndicator.tsx` (`{count,activeIndex}`; green active dot;
  hidden when `count<=1`; numeric fallback for long groups) — near the Header status row.
- NEW `app/components/ListsMenu.tsx` (grouped list of every list, opened from the
  **top-left menu button**; rows dispatch `selectedListChanged` + close; current row
  highlighted, default row starred) — extend the existing Header drawer or mount alongside.
- NEW `app/nav/useListPagerSuppression.ts`: context `{suppressed,setSuppressed}` so an
  intra-board horizontal drag (future) suspends the pager (mirrors `CategoryDrag.draggingId`).
- CHANGE `app/components/ListItem.tsx`: flip swipe-to-delete from right (`dx>0`) to
  **left** (`dx<0`, threshold `-SCREEN_WIDTH*0.32`, delete bg on right edge); pager yields a
  short left-on-row to delete, captures long-left / any-right for paging.
- CHANGE `app/components/Header.tsx`: top-left menu button opens `ListsMenu`; add top-right
  **default star** (`star`/`star-outline`, green when default) → `defaultListSet` +
  persist; host `PositionIndicator` in the status row.
- CHANGE `app/index.tsx` (`AppInner`): wrap the list view in `<ListSwipePager>`; call
  `useListPager`; on launch resolve+dispatch the default list (`resolveLaunchList`); hydrate
  `defaultListId`; `canPage` false while a modal/add-bar/menu is open.

## Kanban screens (`listam-mobile/app/components/kanban/`)
- NEW `ticket.ts` (ported from desktop `src/ticket.mjs`, DOM bits dropped) — pure reuse of
  `@listam/domain/kanban`.
- NEW board view: `groupByStatus(items, config)` → columns; **switch columns by tapping a
  segmented control** (reuse the `SegmentedSetting` chip pattern in `Header.tsx`), one
  column shown at a time; cards via `ticketBadges` (priority, assignee, checklist count,
  live in-progress timer, on-time/over/undertime badge); FAB adds a ticket. Fires
  `sendRPC(RPC_GET_BOARD_CONFIG)` on open.
- NEW ticket detail (full-screen) + status changer (sends one `RPC_UPDATE` via
  `buildStatusChange`; backend freezes time/timeliness) + block body (reuse block helpers,
  render markdown with an RN markdown view, not `innerHTML`).
- NEW rigor create form: `validateRigorDraft(draft, config)` before `sendRPC(RPC_ADD, {text,
  listType:'kanban', status:'todo', description, checklist, estimatedHours, estimatedComplexity})`;
  owner-gated rigor toggle (canAdminister) sends `RPC_SET_BOARD_CONFIG`.
- NEW congruency view: `selectWriterStats(items)` (= `computeCongruency`) cards (mono bars).
- New-list bottom sheet (grocery vs kanban) → `createListThunk`. New components use Ionicons
  (`cart`, `grid`/`apps`, `star`, `menu`, `add`, `chevron-*`, `checkmark`, `folder`) and a
  custom checkbox; complexity slider via `@react-native-community/slider` (new dep — confirm)
  or a small custom Pressable track.

## i18n & theme
- Kanban/ticket/board keys already exist in all 6 `@listam/i18n` catalogs (shared). Add only
  NEW nav keys (`nav.toast.enteredGroup {group}`, `nav.hint.jumpArmed`, `board.configDenied`,
  group/menu/default-star labels) to all 6 + the `index.d.ts` `MessageKey` union; the i18n
  parity test gates it.
- Strictly monochrome + green per approved mockups: consume `useTheme()` tokens only; green
  (`colors.accent`) reserved for active/positive (default star, FAB, active column/tab, live
  timer, done/on-time, primary actions, slider).

## Testing
`node --test` only (no Jest/component tests) — co-locate `.mjs` tests under
`listam-mobile/backend/lib/` (the `test:security` glob) and extract pure logic to `.mjs` the
`.ts` imports:
- `list-registry.test.mjs` — `@listam/domain/list-registry` `reduceRegistry` (LWW, deletes,
  ordering, unfiled→Ungrouped).
- `list-nav.test.mjs` — `listNav` next/prev within group, cross-boundary toast, `jumpGroup`,
  no-wrap edges, single-list/single-group, `resolveLaunchList` stale default.
- `kanban-ticket.test.mjs` — ported `ticket.ts` helpers (`groupByStatus`, `buildStatusChange`,
  `ticketBadges` live timer, `validateRigorDraft`, block round-trips). Domain math itself is
  already covered in `packages/domain/kanban.test.mjs` — don't duplicate.
- `board-config-slice` / `listRegistrySlice` pure reducers/selectors.

## Verification (end-to-end)
1. `npm test` in `listam-mobile` (+ `listam-packages` for the domain/list-registry tests) — green.
2. Expo simulator (`npm run … ios`/`android` or Expo Go): create a grocery and a kanban list via
   the new-list sheet; file them into groups; star a default and relaunch (opens there);
   swipe left/right between lists, confirm the **group-boundary toast**; long-press an empty
   area + swipe to **jump a group**; confirm grocery delete now swipes LEFT; on a kanban list,
   switch columns by **tapping** chips and swipe to change LIST (no conflict); create a ticket
   under rigor (validation blocks missing fields); move a ticket and confirm the on-time badge;
   open congruency.
3. Two-device run: list/group create + reorder on device A appears on device B (registry sync);
   a ticket completed on A shows the same timeliness on B; default list differs per device.

## Risks / edge cases
- Reserved meta-items must be filtered out of EVERY user-facing view (groceries, board,
  kanban, counts) — centralize an `isRegistryItem` guard. If overloading items feels wrong,
  switch to the owner-signed `list-registry` record fallback (more backend work).
- Gesture arbitration is the highest risk: vertical FlatList scroll must never be captured
  (axis-lock is the one invariant); category long-press-drag (280ms on rows) vs jump-arm
  (~250ms on blank space) are disjoint by surface; verify on device.
- Any-writer registry edits race under LWW (two peers rename a group) — last write wins,
  acceptable; note it.
- New dep only if the slider needs `@react-native-community/slider` — confirm before adding
  (else custom track).
- Desktop multi-list/group UI is NOT in scope here; the shared registry reducer lets desktop
  adopt it later for parity.

## Suggested build order
1. `@listam/domain/list-registry` + tests (pure).
2. Mobile state: `boardConfigSlice`, registry projection/slice, `preferences.defaultListId`,
   `_useWorklet` decoder + RPC re-exports + tests.
3. Nav layer: `listNav` + tests → `useListPager` → `ListSwipePager` + `PositionIndicator` →
   `ListsMenu` → `index.tsx`/`Header.tsx` wiring → `ListItem` delete flip.
4. Kanban: port `ticket.ts` + tests → board (tap columns) → ticket detail + status change →
   rigor create → congruency → new-list sheet.
5. i18n nav keys (6 catalogs) + monochrome/green pass; simulator + two-device verification.
