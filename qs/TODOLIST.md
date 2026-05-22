# QuickySitter — TODO list

## Script-name probe migration

Inventory of remaining `llGetInventoryType(<script_name>) == INVENTORY_SCRIPT`
probes across the QS fork, with the rationale for each and the migration
option that would eliminate it. The goal is to make QS scripts depend
on link-message protocols (QSALIVE, QSDUMP) rather than literal script
names so creators can rename/repackage without breaking detection.

See `qs/PROTOCOL.md` § QSALIVE and § QSDUMP for the announce/probe
patterns the migrated paths use.

## Current state (after sitA 0.902, sitB 0.035, adjuster 0.044, select 0.024, etc.)

| File | Line | Variable / String | Purpose | Migration option |
|------|------|-------------------|---------|------------------|
| `[QS]boot.lsl` | 739 | `dump_plugins + [camera_script]` | DUMP cascade plugin discovery | keep — `[AV]camera` is stock-AVsitter protocol surface; no `[QS]camera` fork planned (see Recently retired) |
| `[QS]sitB.lsl` | `select_present()` body | `[AV]select` fallback inventory probe | stock-AVsitter backward-compat | keep — defensive, fires only when QS_SELECT_HELLO flag missed |
| `[QS]adjuster.lsl` | 444, 822, 940 | `camera_script="[AV]camera"` | CAMERA submenu visibility + 90174-dispatch to stock plugin | keep — `[AV]camera` is stock-AVsitter protocol surface; no `[QS]camera` fork planned (see Recently retired) |
| `[QS]root.lsl` | 33 | `script_basename`, `av_script_basename`, `menu_script` | root-prim integrity check (defensive; `menu_script` probes stock `[AV]menu` for menu-prop-only linksets, kept) | runtime-only, fine to keep |

**Recently retired:**
- `[QS]sitA` L24 `memoryscript = "[QS]sitB"` hardcode — sitA 0.902 derives the paired sitB basename from `main_script` via s/sitA/sitB/ (symmetric to sitB's sitB→sitA derivation in sitB 0.032). Renamed packs ([FOO]sitA + [FOO]sitB) now work without touching this file. Removal-detection probe at L1322 (now reads derived `memoryscript`) kept — a deleted script can't broadcast goodbye.
- `[QS]sitA` L478 sitB-wait — dropped in 0.283 (boot-style fix)
- `[QS]select` L91 count loop — QSALIVE-driven in 0.022 (matches adjuster 0.043)
- `[QS]sitA` L998 adjuster-presence — replaced by QS_ADJUSTER_HELLO (90091) broadcast from adjuster 0.044, cached in sitA 0.284
- `[QS]sitA` L101/L483/L1289 `main_script` hardcode — sitA 0.285 derives the basename from `llGetScriptName()` (strip slot suffix), so the `"[QS]sitA"` literal is gone. Creator-renamed forks ("[AV]sitA", "[FOO]sitA") work without touching this file as long as all sitA scripts share the basename.
- `[QS]sitB` L19/L317 dead `main_script` global + L293 dual-probe count loop — sitB 0.032 derives the sitA basename from its own name via `sitB`→`sitA` string-replace; dropped the unused global and the `[QS]/[AV]` dual probe.
- `[QS]sitB` derived-prefix count loop — sitB 0.034 swaps the sitB→sitA derivation for QSALIVE-cached `number_of_sitters` (same pattern as adjuster/select). Last inventory-probe-for-sitter-discovery gone from sitB.
- `[QS]sitB` `[QS]select` probe in `select_present()` — replaced by QS_SELECT_HELLO (90092) announce from select 0.024, cached in sitB 0.035. `[AV]select` literal stays as stock backward-compat fallback (fires only when no QS broadcaster is present).
- `[AV]faces` probes across the fork — `[QS]faces` (≥ 0.902) ships and announces via QS_FACES_HELLO (90090) on state_entry + via QSDUMP_HELLO for boot's DUMP cascade. sitA + adjuster gate their `[FACES]`/`[EXPRESSION]` menu entries on a cached `faces_present` flag (sitA L44/L1072, adjuster L48/L904); boot's `dump_plugins` picks faces up automatically, so the hardcoded `expression_script` in the cascade list is gone (boot L739 now reads `dump_plugins + [camera_script]`).
- `[QS]adjuster` `prop_script` references — adjuster 0.912 migrates the `[PROP]` gate to a cached `prop_present` flag driven by QS_PROP_HELLO (90089), broadcast by `[QS]prop` 0.901 on state_entry / on_rez / QSALIVE-reply (faces pattern). With the L898 diagnostic simplified to a generic "prop plugin script" string, the `prop_script` string global at L25 was also dropped — adjuster.lsl no longer contains a `"[QS]prop"` literal anywhere. Net cost ~60 bytes static after offsetting the removed declaration + concatenation.
- `[QS]menu` — removed from the fork entirely 2026-05-20. The fork originally existed to fix duplicate-menu-management when stock `[AV]menu` coexisted in a linkset with a QS sit system (stock probed for `[AV]sitA`, missed `[QS]sitA`, stayed active alongside `[QS]adjuster`). Decision: menu-prop objects and QS-sitter furniture are mutually exclusive use cases — menu-only linksets use stock `[AV]menu` in a sitter-less object. Removed: `qs/[QS]menu.lsl`, the menu row in the migration table, Quick wins #1 (`[QS]menu` prop_script migration), the `[RESET]`-button-doesn't-reload-AVpos section, and all menu references in the AVsitter-plugin probes section. `[QS]root.lsl`'s defensive `menu_script="[AV]menu"` probe stays — it supports the menu-prop-only linkset config and never referenced `[QS]menu`.
- `[QS]boot` LSD-wipe warning — boot 0.912 extends the existing `linkset_data` handler with a `LINKSETDATA_RESET` branch that surfaces a one-shot `llOwnerSay("[QS] LSD was wiped — cached state inconsistent. Reset scripts or re-rez to restore.")`. Triggers on `/88` or any `llLinksetDataReset` call. Boot itself re-seeds on the next `state_entry` (`qs:boot:asset` is gone → skip-check fails) but sibling-script RAM caches (sitA/sitB/adjuster) stay stale until the user manually resets or re-rezzes — the warning is the cue. Cost: ~115 bytes static; spam-bounded (1 message per wipe per furniture, wipes are explicit user actions).
- `[AV]camera` migration — **declined 2026-05-20** after verifying stock `[AV]camera`'s name-bound code is dead. Its `main_script="[AV]sitA"` global (avstock `[AV]camera.lsl` L19) is only referenced by `get_number_of_scripts()` (L32-40), which is **never called anywhere in the file** — pure dead code. All working code paths in [AV]camera are protocol-based (90020/90022/90045/90065/90230/90231/90174 use `SCRIPT_CHANNEL` and sender-filtering, not script-name matching), so stock [AV]camera runs correctly in QS-sitter setups without modification. Our remaining `camera_script="[AV]camera"` references (boot L28/L739 DUMP cascade, adjuster L444/L822/L940 menu gate + 90174-dispatch) are stock-AVsitter-protocol surface, not internal coupling — they're equivalent to having a hardcoded `"[AV]camera"` because that **is** the protocol-mandated name. No `[QS]camera` fork planned; no migration possible.
- AVpos notecard without `SITTER` directive — boot 0.913 synthesizes a virtual `SITTER 0` when the first pose-ish directive (POSE / SYNC / MENU / TOMENU / BUTTON / SEQUENCE / `{posename}<...>` splice line) arrives with `current_channel == -1`. Replicates stock AVsitter's "implicit slot 0" behavior (in stock, each `[AV]sitA` instance had its own SCRIPT_CHANNEL baked into the script name, so the slot was never implicit; QS's consolidated boot parser made it implicit by accident). Verified safe: empty SITTER_INFO falls back to first POSE name as slot button via [`[QS]select`'s existing fallback](./[QS]select.lsl) L210-214, and empty GENDERS returns FALSE for gender-based swap checks rather than matching falsely. The companion case "no MENU directive, only POSE entries" (A2 in the original analysis) was deferred — current evidence suggests sitA's MENU_LIST picks up all pose names regardless of type, so likely works as a flat list already; reconsider only if a real-world notecard with this shape surfaces broken end-to-end.
- `[QS]boot` self-check false-positive during updater runs — boot 0.914 resets the self-check safety-net timer on every `CHANGED_INVENTORY` while `selfcheck_pending` is TRUE; boot 0.915 extends the timer from 5s → 10s for additional headroom on busy regions. The updater swaps sibling scripts one-by-one over a window that can exceed 5s, and the previous code fired `self_check_report()` mid-swap and reported false-positive `"[QS]sitA missing"` ERRORs for scripts the updater was about to re-add. Now each inventory event during the pending window pushes the 10s deadline back, and the report only fires once inventory has been quiescent for a full 10s. Untouched: notecard-asset-key-driven reset path (`llResetScript()` still wipes LSD when the AVpos changes), `try_complete_selfcheck()` early-exit when both flags flip TRUE, and the legitimate "actually missing" detection (after inventory settles with sitA truly absent, the timer fires normally). Considered + rejected: full reset on every `CHANGED_INVENTORY` (Variante B) — solves the same race at much higher cost (Reset-Karussell on texture swaps, prop drops, plugin additions) without meaningful additional benefit because boot's state is already idempotent vs notecard via the `qs:boot:asset` skip-check from 0.901.

## Migration patterns by cluster

### Sitter-slot counting (`[QS]sitA N`) — resolved

External consumers (plugins, adjuster, select) use QSALIVE-cap count
populated from sitA-slot-0's 90097 reply. Internal sitA + sitB
counts use inventory probes with a basename derived from the script's
own name (`llGetScriptName()` strip-suffix in sitA 0.285, sitB→sitA
replacement in sitB 0.032). No hardcoded `"[QS]sitA"` left in either
file.

`SCRIPT_CHANNEL` is still derived from the script's own name suffix
— that's a permanent feature of AVsitter's slot model, not a TODO.

### AVsitter-plugin probes (resolved)

These names are part of the AVsitter protocol, not internal coupling.
Stock plugins identify themselves by exact script name in inventory
and in the `id` field of 90020/90022 link messages.

QSDUMP (boot 0.032) replaced the prop hardcode in boot's cascade by
having `[QS]prop` announce itself via 90094/90095. `[QS]faces`
(≥ 0.902) followed the same pattern via QSDUMP_HELLO + QS_FACES_HELLO
(90090), so boot's cascade only hardcodes `camera_script` for the
one stock plugin we don't fork.

adjuster's `[PROP]` gate migrated in 0.912 via QS_PROP_HELLO (90089;
see "Recently retired" above). `[QS]menu` was retired from the fork
2026-05-20 — menu-prop linksets now use stock `[AV]menu` directly.
`[AV]camera` stays stock — no `[QS]camera` fork planned (see Recently
retired for the dead-code analysis showing stock [AV]camera's
name-bound paths are unused).

## Big refactor — slot identity without script names

The intrinsic `[QS]sitA N` naming convention forces sitA scripts to
discover their slot from their own script name. To eliminate this,
boot would assign slots via a register-on-state_entry handshake, and
sitA would persist its assigned slot in LSD keyed by some other
bootstrap identifier (UUID generated at first run?).

Cost: breaks AVsitter-stock compatibility for sitter slots. Stock
plugins probing `[AV]sitA N` would never find QS sitters.

Benefit: complete script-name independence on the sitter side.

Parked. Reconsider only if AVsitter compat is dropped as a goal.

## Watchdog-only standby — global script-time savings

Every running QS fork script consumes simulator script time even
when the furniture is idle (no avatars seated, no recent menu
activity). On furniture-heavy regions this adds up across many
objects.

**Idea:** keep exactly one watchdog script alive per furniture
piece. The watchdog listens for the events that should wake the
rest of the system — touch, sit, HUD LinkMsg, region restart — and
brings sibling scripts back via `llSetScriptState(..., TRUE)`. All
other QS fork scripts are put to sleep with
`llSetScriptState(..., FALSE)` after a configurable idle timeout.

**Open design questions:**
- Which script is the watchdog? `[QS]boot` already owns the
  bootstrap cascade and is a natural candidate, or a dedicated
  `[QS]watchdog` fork.
- How does the watchdog know which siblings to wake? Inventory
  probes by name reintroduce the script-name coupling we just
  removed. Use the QSALIVE-cached basename list collected during
  normal operation, persisted in LSD so it survives region restart.
- Wake-from-sit: who catches the sit event when sitA is asleep?
  Either the watchdog stays in root prim and forwards via LinkMsg,
  or sitA stays awake alongside the watchdog and only the helper
  scripts (adjuster, menu, select, prop, ...) sleep.
- State preservation: LSD already persists across script enable /
  disable cycles, so resume should be lossless. Listeners and
  timers are NOT preserved → the watchdog must own every listener
  and every timer during standby.
- Wake latency: how responsive is the first touch / menu open
  after sleep? Needs measurement on a real region.
- Standby trigger: timer-based (e.g., N seconds idle) vs. explicit
  ("go to sleep" menu item or HUD button).
- AVsitter compatibility: stock AV plugins (faces, camera) won't
  cooperate with our standby protocol. Decide whether to leave
  unknown plugins running or to sleep them anyway with a wake
  broadcast on the relevant LinkMsg.

**Out of scope here:** memory savings. `llSetScriptState(FALSE)`
keeps the heap allocated; this is purely a script-time optimization.

## Open improvements

- **ALL-mode sitter cap.** `[QS]hudproxy.lsl`'s ALL fan-out
  (`change()` L590–614 in hud-repo) iterates the full `getSitterList()`
  and does one `llJsonGetValue(sJsonSitters,[sUID,"p"])` + one
  `mutateOneSitter` + one 90057 LinkMsg per matching sitter. At 6+
  sitters in the same pose this approaches the historical SHC point
  documented in the `slotToUID` comment (L94–96) — the old O(N²)
  JSON-parse path collided at 6 sitters, and while slot lookup is
  now O(1), the ALL fan-out still does N JSON parses + N link-messages
  per click. Plan: refuse ALL when `iLen > 6` with a chat hint to the
  triggering user ("Group too large for ALL — use ME/YOU"). The
  registration cap (`[QS]hudproxy.lsl` L1014: `>= 7`) stays as-is;
  only the broadcast path gets the new guard so ME/YOU continue to
  work up to 7 sitters. Verify under region stress (6× sitter, same
  pose, repeated ZUP) before locking the value in — drop to 5 if heap
  headroom stays tight.

- **RLV: general plumbing review.** HUD-side SWAP gate shipped in
  `[QS]hudproxy.lsl` 0.904 — `openSwapDialog` refuses HUD-initiated
  seat swaps when the cached 90201/90202 flag from `[AV]root-security`
  is set, bouncing a chat hint to the requesting user. The sitB
  stock-menu `[SWAP]` path was intentionally left intact so RLV scenes
  that want to allow it can still use that route. Still open: the rest
  of the RLV plumbing in the fork is stale — review all sit/unsit/
  pose-change paths for RLV-awareness, audit which restrictions are
  honored vs. silently bypassed, decide whether per-sitter RLV state
  (vs. the current furniture-global flag) is needed for finer gates,
  and document the supported RLV verbs in `PROTOCOL.md`.

