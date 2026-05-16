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
| `[QS]boot.lsl` | 506 | `dump_plugins + [expression_script, camera_script]` | DUMP cascade plugin discovery | prop already announces via QSDUMP; expression/camera need the same once forked |
| `[QS]sitA.lsl` | 984 | `expression_script="[AV]faces"` | FACE-directive integration | wait for `[QS]faces` fork; either keep hardcoded or migrate via a QSPLUGIN-announce style protocol |
| `[QS]sitB.lsl` | `select_present()` body | `[AV]select` fallback inventory probe | stock-AVsitter backward-compat | keep — defensive, fires only when QS_SELECT_HELLO flag missed |
| `[QS]adjuster.lsl` | 406, 694, 822 | `camera_script="[AV]camera"` | CAMERA submenu visibility | needs `[QS]camera` fork before QSDUMP-style migration |
| `[QS]adjuster.lsl` | 787 | `prop_script="[QS]prop"` | PROP submenu visibility | could read boot's `dump_plugins` via a new probe, or QSDUMP-cap on prop |
| `[QS]adjuster.lsl` | 800 | `expression_script="[AV]faces"` | EXPRESSION submenu visibility | wait for `[QS]faces` fork |
| `[QS]menu.lsl` | 275, 558 | `prop_script="[QS]prop"` | menu items for prop | same as adjuster L787 |
| `[QS]root.lsl` | 33 | `script_basename`, `av_script_basename`, `menu_script` | root-prim integrity check (defensive) | runtime-only, fine to keep |

**Recently retired:**
- `[QS]sitA` L24 `memoryscript = "[QS]sitB"` hardcode — sitA 0.902 derives the paired sitB basename from `main_script` via s/sitA/sitB/ (symmetric to sitB's sitB→sitA derivation in sitB 0.032). Renamed packs ([FOO]sitA + [FOO]sitB) now work without touching this file. Removal-detection probe at L1322 (now reads derived `memoryscript`) kept — a deleted script can't broadcast goodbye.
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

## AVpos notecard edge case — no MENU, no sitter-slot prefix

Some single-sitter AVpos notecards omit both the MENU section and any
sitter-slot prefix on POSE directives. Example shape:

```
POSE FSit1|FSit1
POSE FSit2|FSit2
...
{FSit1}<0.438,0,0.77><0,0,0>
{FSit2}<0.438,0,0.77><0,0,0>
...
PROP1 FCoffee|mug|G1|<...>|<...>|left hand
PROP  Laptop|laptop|G1|<...>|<...>
```

No MENU lines, no `[N]` slot prefix on POSE — the notecard implicitly
addresses sitter 0 only. (Mixed `PROP1` / `PROP` in the same card is
also part of the real-world example.)

**Open question:** does the QS pipeline handle this correctly today
(auto-fall-back to a flat single-sitter pose list / synthesize a default
menu), or does it silently misbehave?

Action: load such a notecard against the current sitA / boot / menu /
prop chain and verify end-to-end. If the result is broken or confusing,
pick one:
- **Tolerate** — auto-build a flat "POSES" menu from the bare POSE list,
  treat all entries as slot 0.
- **Warn** — load it, but emit a one-shot `llOwnerSay` to the creator
  ("notecard has no MENU section; defaulting to flat list").
- **Reject** — refuse to load and explain what is missing.

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

## `[RESET]`-button in `[QS]menu` does not reload AVpos

`[QS]menu` advertises `[RESET] = Reload notecard.` in its help text
(`[QS]menu.lsl` L187), but the handler at L531-538 only calls
`llResetOtherScript(prop_script)` + `llResetScript()` on itself —
`[QS]boot` is never touched, so AVpos is *not* re-read. Today this
mostly happens to work because boot itself re-reads on every state_entry
(see boot 0.026 regression), so any unrelated reset of boot also reloads
AVpos. Once boot's state_entry skip-check lands (boot ≥ 0.901, cached
asset-key via `qs:boot:asset`), `[RESET]` will visibly stop reloading
the notecard.

Options:
- **menu wipes the marker** — `llLinksetDataDelete("qs:boot:asset")` +
  `llResetOtherScript("[QS]boot")` before the self-reset. Simple, no
  new protocol.
- **menu sends LinkMsg to boot** — new "force-reload" num that boot
  reacts to by clearing its own marker + `llResetScript()`. Cleaner
  surface but adds a protocol number.
- **Drop the button** — if creators don't need a manual reload (notecard
  save already triggers it via CHANGED_INVENTORY), retire the menu item
  and update the help text. Smallest code, biggest UX change.
