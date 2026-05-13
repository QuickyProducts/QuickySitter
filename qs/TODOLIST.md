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
| `[QS]sitA.lsl` | 1293 | `memoryscript` | sibling check for reset trigger | acceptable runtime defensive; could migrate via sitB QS_HELLO announce later |
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
   QS_ADJUSTER_HELLO pattern).
2. `[QS]sitA` L1293 memoryscript sibling-check — sitB could announce
   via `QS_SITB_HELLO` so sitA caches presence rather than probing
   inventory in the CHANGED_INVENTORY handler.
