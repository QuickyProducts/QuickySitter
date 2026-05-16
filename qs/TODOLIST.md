# QuickySitter — TODO list

## Script-name probe migration

Inventory of remaining `llGetInventoryType(<script_name>) == INVENTORY_SCRIPT`
probes across the QS fork, with the rationale for each and the migration
option that would eliminate it. The goal is to make QS scripts depend
on link-message protocols (QSALIVE, QSDUMP) rather than literal script
names so creators can rename/repackage without breaking detection.

See `qs/PROTOCOL.md` § QSALIVE and § QSDUMP for the announce/probe
patterns the migrated paths use.

## Current state (after sitA 0.285, sitB 0.035, adjuster 0.044, select 0.024, etc.)

| File | Line | Variable / String | Purpose | Migration option |
|------|------|-------------------|---------|------------------|
| `[QS]boot.lsl` | 506 | `dump_plugins + [expression_script, camera_script]` | DUMP cascade plugin discovery | prop already announces via QSDUMP; expression/camera need the same once forked |
| `[QS]sitA.lsl` | 984 | `expression_script="[AV]faces"` | FACE-directive integration | wait for `[QS]faces` fork; either keep hardcoded or migrate via a QSPLUGIN-announce style protocol |
| `[QS]sitA.lsl` | 1293 | `memoryscript` | sibling check for reset trigger | **keep** — defensive runtime check on CHANGED_INVENTORY only; removal-detection doesn't fit announce-based patterns naturally (a removed script can't broadcast goodbye) |
| `[QS]sitB.lsl` | `select_present()` body | `[AV]select` fallback inventory probe | stock-AVsitter backward-compat | keep — defensive, fires only when QS_SELECT_HELLO flag missed |
| `[QS]adjuster.lsl` | 406, 694, 822 | `camera_script="[AV]camera"` | CAMERA submenu visibility | needs `[QS]camera` fork before QSDUMP-style migration |
| `[QS]adjuster.lsl` | 787 | `prop_script="[QS]prop"` | PROP submenu visibility | could read boot's `dump_plugins` via a new probe, or QSDUMP-cap on prop |
| `[QS]adjuster.lsl` | 800 | `expression_script="[AV]faces"` | EXPRESSION submenu visibility | wait for `[QS]faces` fork |
| `[QS]menu.lsl` | 275, 558 | `prop_script="[QS]prop"` | menu items for prop | same as adjuster L787 |
| `[QS]root.lsl` | 33 | `script_basename`, `av_script_basename`, `menu_script` | root-prim integrity check (defensive) | runtime-only, fine to keep |

**Recently retired:**
- `[QS]sitA` L478 sitB-wait — dropped in 0.283 (boot-style fix)
- `[QS]select` L91 count loop — QSALIVE-driven in 0.022 (matches adjuster 0.043)
- `[QS]sitA` L998 adjuster-presence — replaced by QS_ADJUSTER_HELLO (90091) broadcast from adjuster 0.044, cached in sitA 0.284
- `[QS]sitA` L101/L483/L1289 `main_script` hardcode — sitA 0.285 derives the basename from `llGetScriptName()` (strip slot suffix), so the `"[QS]sitA"` literal is gone. Creator-renamed forks ("[AV]sitA", "[FOO]sitA") work without touching this file as long as all sitA scripts share the basename.
- `[QS]sitB` L19/L317 dead `main_script` global + L293 dual-probe count loop — sitB 0.032 derives the sitA basename from its own name via `sitB`→`sitA` string-replace; dropped the unused global and the `[QS]/[AV]` dual probe.
- `[QS]sitB` derived-prefix count loop — sitB 0.034 swaps the sitB→sitA derivation for QSALIVE-cached `number_of_sitters` (same pattern as adjuster/select). Last inventory-probe-for-sitter-discovery gone from sitB.
- `[QS]sitB` `[QS]select` probe in `select_present()` — replaced by QS_SELECT_HELLO (90092) announce from select 0.024, cached in sitB 0.035. `[AV]select` literal stays as stock backward-compat fallback (fires only when no QS broadcaster is present).

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

### AVsitter-plugin probes (`[AV]prop` / `[AV]faces` / `[AV]camera`)

These names are part of the AVsitter protocol, not internal coupling.
Stock plugins identify themselves by exact script name in inventory
and in the `id` field of 90020/90022 link messages.

QSDUMP (boot 0.032) replaces the prop hardcode in boot's cascade by
having `[QS]prop` announce itself via 90094/90095. The same pattern
generalizes to any QS-side use case once `[QS]faces` / `[QS]camera`
forks exist.

Until those forks: adjuster and menu probe `prop_script="[QS]prop"`
for menu-item visibility. These could also be replaced by an
"is this plugin DUMP-capable?" probe consuming boot's `dump_plugins`
list, or by a separate per-feature QSALIVE-cap protocol.

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

## Quick wins still on the table

1. `[QS]menu` prop_script — consume boot's `dump_plugins` list via a
   new "active DUMP plugins?" probe, or extend QSDUMP with a
   per-plugin "I'm here" cap that menu can cache (mirrors the
   QS_ADJUSTER_HELLO / QS_SELECT_HELLO pattern).

## Open improvements

- **`[QUICKYHUD]` button visibility / hint.** Currently the `[QUICKYHUD]`
  entry in the adjust menu (gated in `[QS]sitA.lsl`, branch in
  `[QS]adjuster.lsl` ~L635) is shown to anyone with menu access. Mirror
  the `[HELPER]` button's owner-gating: either hide `[QUICKYHUD]` for
  non-owners entirely, or keep it visible and emit a hint message
  ("only the owner can configure the HUD" or similar) when a non-owner
  taps it. Match whichever pattern `[HELPER]` uses today (check the
  `[HELPER]` dispatch in `[QS]adjuster.lsl` ~L629 and the gating in
  `[QS]sitA.lsl`).

- **RLV: gate SWAP for RLV-locked sitters + general overhaul.** When a
  sitter is restrained via RLV (e.g. `@unsit=n`, `@sit:<uuid>=force`),
  SWAP must be blocked — moving them to another slot violates the
  restriction. Block in two places: the HUD-side `*SWAP*` dispatch
  (`[QS]hudproxy.lsl` / `[QS]hudadmin.lsl` swap dialog) and the
  furniture-side `90030` receiver in `[QS]sitA.lsl`, so direct
  link-message swaps from non-HUD callers (`[QS]select`, `[QS]debug`
  stress-chaos) are also rejected. Detect RLV via the standard RLV
  status query (`@version=<channel>` listen handshake) and cache the
  result per sitter. Beyond SWAP: the rest of the RLV plumbing in
  the fork is stale — review all sit/unsit/pose-change paths for
  RLV-awareness, audit which restrictions are honored vs. silently
  bypassed, and document the supported RLV verbs in `PROTOCOL.md`.

- **Boot: warn on LSD wipe via `linkset_data` event.** `[QS]boot.lsl`
  reads the notecard and populates LSD with config keys. If someone
  runs `/88` (or any path that calls `llLinksetDataReset`), later
  scripts read empty keys with no surfaced error. Add a
  `linkset_data(integer action, string name, string value, integer
  size)` event handler in boot: when `action == LINKSETDATA_RESET`,
  owner-say a clear warning ("LSD was wiped — furniture state may be
  inconsistent, re-rez or reset scripts"). No time-window logic
  needed — the event itself is the trigger.

## Pending verifications

- **Stress test after hudproxy 0.902 (swap-backoff removal).** The
  `90030` 1-second swap-backoff that dropped `90055`/`90260`/`90262`
  was removed because it killed the post-swap state-refresh (avatar
  started at OLD slot's `pr` after swap+HUD-adjust). Backoff was
  originally a heap-diet measure (commit `7a62d6d`) for the 6-sitter
  chaos profile in `[QS]debug.lsl`. Verify via that stress test (15%
  swap rolls under 6-sitter load) that hudproxy doesn't
  Stack-Heap-Collide. If it regresses, switch to a surgical exemption:
  track swap-target UUIDs in a list populated by the `90070` handler
  and bypass backoff only for those, keep backoff for unrelated noise.
