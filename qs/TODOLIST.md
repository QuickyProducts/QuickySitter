# QuickySitter — TODO list

## Open bugs

### ADJUSTMODE lost on SWAP

After 2026-05-13's SWAP-picker migration from hudproxy to hudadmin
(quicky-hud commit `d2ac411`, hudproxy 1.468 / hudadmin 1.232),
performing a SWAP drops the ADJUSTMODE state — the HUD reverts to
the non-adjust layout. User confirms it worked before that commit,
so the regression must be in the migration itself.

**Reproduce**: ≥3-sitter furniture, enable ADJUSTMODE on the HUD,
click `*SWAP*` on the HUD matrix, pick a target slot. Expected:
ADJUSTMODE stays On, matrix keeps the adjust layout. Observed:
layout flips back to the non-adjust matrix.

**Suspect spots** (file:line refs against post-d2ac411 master):

1. `quicky-hud/qs/[QS]hudadmin.lsl:805-808` — the new 90030
   broadcast from hudadmin's `dialog_chan_swap` listen handler:
   ```lsl
   llMessageLinked(LINK_SET, 90030,
       (string)dialog_swap_my_slot, (key)message);
   ```
   Sender changed from hudproxy (pre-d2ac411) to hudadmin. The
   90030 payload is the same (`mySlot` in msg, target slot as
   key in id), but if any downstream consumer filters on
   `sender_num`, it would now see a different link number.
   Audit sitA / sitB / [QS]offset 90030 handlers for sender
   gating.

2. `quicky-hud/qs/[QS]hudproxy.lsl:728-732` — the receive-side
   90030 handler in hudproxy:
   ```lsl
   if (num == 90030)
   {
       fSwapBackoffUntil = llGetTime() + 1.0;
       return;
   }
   ```
   Sender-agnostic on the surface. But pre-d2ac411 the SAME
   script (hudproxy) was both firing AND receiving 90030
   in-event-order. Post-migration the path is: hudadmin fires →
   queued for all scripts → hudproxy receives one event tick
   later. That subtle gap may interact badly with the new HUD
   re-attach triggered by the SWAP cascade (90070 → hudadmin
   `attachHUD`, lines 766-768).

3. `quicky-hud/qs/[QS]hudadmin.lsl:576-598` — `attachHUD()`:
   ```lsl
   string postSay = "";
   key kTex = getHUDTexture();
   if (kTex != NULL_KEY)
       postSay = "*QUICKYTEXTURE*|" + (string)kTex;
   ```
   postSay carries `*QUICKYTEXTURE*` only — no `*ADJUSTMODE*`.
   When 90070 fires during the SWAP cascade and re-attaches the
   HUD (in auto-attach mode, line 766-768), the fresh HUD
   instance starts with `bAdjustMode=FALSE` in hudmatrix L59.
   No 953 broadcast fires either, because `setAdjustmode` only
   broadcasts on state change. **This** explains *why* the new
   HUD looks non-adjust, but not *why it broke specifically at
   d2ac411* — the postSay was already without `*ADJUSTMODE*`
   in master before today. So either re-attach didn't fire
   pre-migration (then the SWAP wouldn't have triggered 90070
   the same way? — unlikely), or there's a different mechanism
   that initialized `bAdjustMode` post-SWAP that the migration
   broke.

**Next investigation step**: in-world test with debug logging in
hudmatrix's `applyDaddyCommand("*ADJUSTMODE*")` and in hudadmin's
`attachHUD` to trace whether the new HUD receives the state at all,
and via which path. Compare with a quick revert of d2ac411 to
confirm the SWAP-migration *is* the regression source.

## Script-name probe migration

Inventory of remaining `llGetInventoryType(<script_name>) == INVENTORY_SCRIPT`
probes across the QS fork, with the rationale for each and the migration
option that would eliminate it. The goal is to make QS scripts depend
on link-message protocols (QSALIVE, QSDUMP) rather than literal script
names so creators can rename/repackage without breaking detection.

See `qs/PROTOCOL.md` § QSALIVE and § QSDUMP for the announce/probe
patterns the migrated paths use.

## Current state (after boot 0.034, adjuster 0.043, sitB 0.031, etc.)

| File | Line | Variable / String | Purpose | Migration option |
|------|------|-------------------|---------|------------------|
| `[QS]boot.lsl` | 506 | `dump_plugins + [expression_script, camera_script]` | DUMP cascade plugin discovery | prop already announces via QSDUMP; expression/camera need the same once forked |
| `[QS]sitA.lsl` | 101 | `main_script="[QS]sitA"` | `get_number_of_scripts()` — own QSALIVE-reply count source | intrinsic to AVsitter slot-naming, hardest to remove (sitA derives `SCRIPT_CHANNEL` from its own name) |
| `[QS]sitA.lsl` | 478 | `memoryscript="[QS]sitB"` | state_entry blocking-wait until sitB exists | same fix as boot 0.025 — drop the wait, rely on `changed(CHANGED_INVENTORY)` |
| `[QS]sitA.lsl` | 483 | `main_script` | state_entry count loop (SITTERS pre-fill) | same as L101 — intrinsic |
| `[QS]sitA.lsl` | 984 | `expression_script="[AV]faces"` | FACE-directive integration | wait for `[QS]faces` fork; either keep hardcoded or migrate via a QSPLUGIN-announce style protocol |
| `[QS]sitA.lsl` | 998 | `adjust_script="[QS]adjuster"` | helper-mode detection | QSALIVE-cap flag on adjuster (e.g. `adjuster`) or new QSPLUGIN announce |
| `[QS]sitA.lsl` | 1289 | `main_script` | changed-handler count loop | same as L101 |
| `[QS]sitA.lsl` | 1293 | `memoryscript` | sibling check for reset trigger | same as L478 |
| `[QS]sitB.lsl` | 97, 152, 180, 393 | `select_present()` (probes `[QS]select` + `[AV]select`) | menu logic varies if select is installed | wrapped in helper (0.031); could become QSALIVE-cap on `[QS]select` |
| `[QS]sitB.lsl` | 293 | literal `"[QS]sitA "` / `"[AV]sitA "` | sitter count loop | intrinsic, but dual-probe for QS/stock compat (0.031) |
| `[QS]adjuster.lsl` | 406, 694, 822 | `camera_script="[AV]camera"` | CAMERA submenu visibility | needs `[QS]camera` fork before QSDUMP-style migration |
| `[QS]adjuster.lsl` | 787 | `prop_script="[QS]prop"` | PROP submenu visibility | could read boot's `dump_plugins` via a new probe, or QSDUMP-cap on prop |
| `[QS]adjuster.lsl` | 800 | `expression_script="[AV]faces"` | EXPRESSION submenu visibility | wait for `[QS]faces` fork |
| `[QS]menu.lsl` | 275, 558 | `prop_script="[QS]prop"` | menu items for prop | same as adjuster L787 |
| `[QS]select.lsl` | 91 | `main_script="[QS]sitA"` + literal `"[AV]sitA"` (dual probe since 0.021) | sitter count loop | could migrate to QSALIVE-driven count (same pattern as adjuster 0.043) |
| `[QS]root.lsl` | 33 | `script_basename`, `av_script_basename`, `menu_script` | root-prim integrity check (defensive) | runtime-only, fine to keep |

## Migration patterns by cluster

### Sitter-slot counting (`[QS]sitA N`)

Affects: sitA (3×), sitB (1×), select (1×).

sitA itself owns the canonical count via its own inventory probe.
Other scripts can adopt the same pattern adjuster used at 0.043:

```lsl
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;

integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;  // pre-reply fallback
}
```

state_entry sends `llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "")`;
link_message handler parses the `QuickySitter|<ver>|<count>|<caps>`
reply and updates the cache. Resize any count-dependent lists on
count change.

sitA's own `get_number_of_scripts()` (line 101) and SITTERS pre-fill
(line 483) cannot use this pattern — slot-0 sitA is the *responder*,
and `SCRIPT_CHANNEL` is derived from `llGetScriptName()`'s suffix
either way. AVsitter's slot model bakes the script-name dependency
into the protocol; eliminating it would require a registrar refactor
(see "Big refactor" below).

### sitB-Wait (memoryscript)

sitA blocks in `state_entry` until `[QS]sitB` exists. Same install-
time guard `[QS]boot` had before 0.025. The QS fix was to drop the
wait entirely and rely on `changed(CHANGED_INVENTORY)` to re-run on
install — `[QS]sitA` can adopt the same pattern.

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

### Select-plugin presence

sitB's `select_present()` wraps both `[QS]select` and `[AV]select`
probes (0.031). Migrating to QSALIVE-cap on `[QS]select` would
remove even the literal `[AV]select` fallback eventually.

### Adjuster presence

sitA L998 probes `adjust_script="[QS]adjuster"` for helper-mode
detection. Trivial migration to a QSALIVE-cap announced by adjuster
(e.g. add `adjuster` to its 90097 reply payload's caps field).

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

1. `[QS]sitA` sitB-Wait — drop `while (llGetInventoryType(memoryscript)…)`,
   match boot 0.025's pattern.
2. `[QS]select` count loop — same QSALIVE refactor adjuster did at 0.043.
3. `[QS]sitA` adjuster-presence (L998) — QSALIVE-cap on adjuster.
4. `[QS]menu` prop_script — consume boot's `dump_plugins` list via a
   new "active DUMP plugins?" probe.
