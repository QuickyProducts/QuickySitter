# QuickySitter — Testplan

Funktionale Test-Coverage. SYNC-Drift-Investigation und Re-Sync-
Architektur sind bewusst auf einen Smoke-Test reduziert (TC-021); für
Architektur-Details siehe [`PROTOCOL.md` § Re-Sync trigger](./PROTOCOL.md#re-sync-trigger--90271)
und die Git-Historie.

---

## A. Single-Sitter Pose-Lifecycle

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-001 | Normaler Posewechsel | niedrig | Switch ohne Lücken-Frame | keine T-Pose zwischen alt/neu; `llGetAnimationList` enthält neue Anim ≤1 s | nein |
| TC-002 | 5 Posewechsel in <2 s | mittel | letzter Klick gewinnt | `llGetAnimationList` nach 1 s = letzte Anfrage; keine Anims aus verworfenen Klicks aktiv | evtl |
| TC-010 | Non-loop Animation endet | mittel | definierter Übergang | sitA-`timer` feuert; `OLD_ANIMATION_FILENAME` gestoppt | ja |
| TC-014 | 20 Posewechsel in Folge | hoch | keine Race-Condition | finale Pose match; keine Ghost-Einträge in `llGetAnimationList` | ja |
| TC-015 | Unsit während Posewechsel | mittel | sauberer Cleanup | `release_sitter` ruft `llStopAnimation`; `MY_SITTER == ""` nach 1 s | nein |

## B. Multi-Sitter SYNC (Smoke-Test)

Der einzige verbleibende SYNC-Test. Camera-Zoom-Out lässt den Avatar
aus der Interest-List fallen und triggert beim Re-Acquisition ein
Restart-Signal vom Sender (hudproxy 90271). Reicht als Smoke-Test für
die ganze Re-Sync-Pipeline — wir testen nicht alle Drift-Ursachen,
nur dass der Mechanismus überhaupt greift.

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-021 | Avatar zoomt aus Draw-Distance raus & wieder rein | hoch | nach Re-Acquisition synchron | visuell synchron innerhalb 30 s nach Wiedereintritt | ja |

## C. AO / Animation-Konflikte

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-003 | AO aktiv (Idle/Walk), Bento-Body-Pose | hoch | Pose dominiert in den belegten Bone-Slots | Pose-Anim in `llGetAnimationList`; visuell keine AO-Bewegung in Pose-Slots | ja |
| TC-004 | AO während Pose toggle (an/aus/an) | hoch | kein Drift, kein Position-Snap | Phasen-stabil; Avatar-Position ±5 cm konstant | ja |
| TC-017 | Bento-Pose + Bento-Hand-AO | hoch | Hände bleiben pose-gesteuert | Hand-Anim der Pose in `llGetAnimationList`, nicht AO-Hand | ja |

## D. Netzwerk / Region

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-005 | Viewer-Lag (>1 s Stutter) | hoch | Pose startet verzögert, korrekt | nach Lag korrekt; Recovery <5 s | ja |
| TC-007 | Teleport sitzend | kritisch | Sit-Status + Pose erhalten | `MY_SITTER` unverändert; Anim läuft weiter; kein Unsit | ja |
| TC-008 | Region-Crossing sitzend | kritisch | Position stabil, Pose läuft | KFM-pause/play greift; Positionssprung <0.5 m | ja |
| TC-011 | Netzwerk-Drop 5–10 s | kritisch | automatische Recovery | Pose nach Reconnect <10 s synchron | ja |
| TC-013 | Sim-Lag >0.5 s/Frame | hoch | Queue stabil | letzte Anfrage angekommen; `MENU_LIST` intakt | ja |
| TC-020 | Region-Restart, Sitter persistiert nicht | kritisch | nach Re-Sit Default-Pose aus LSD | LSD-Persistenz greift; `boot_done == TRUE` vor erstem Sit | ja (manuell) |

## E. Avatar-Lifecycle

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-016 | 10× Sitzen/Unsitzen | mittel | keine Ghost-States | keine doppelten Listener; `MY_SITTER` sauber | nein |
| TC-018a | Outfit-Replace, kein Sitter-Detach | hoch | Pose-Anim läuft weiter | `llGetAnimationList` stabil | nein |
| TC-018b | Outfit-Add (Layer) | niedrig | keine Wirkung erwartet | Pose unverändert | nein |
| TC-019 | Avatar-Rebake | hoch | Pose bleibt aktiv | `llGetAnimationList` stabil über Rebake | nein |

## F. State-Recovery

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-006 | Anim-Asset nicht im Viewer-Cache | hoch | Nachladen, dann korrekt | initial 1–3 s evtl T-Pose; danach korrekt | ja |
| TC-009a | `[QS]root.lsl` Reset | kritisch | aus LSD rekonstruierbar | aktive Sitter bleiben gesittet; LSD-Re-Init | ja |
| TC-009b | `[QS]sitA.lsl` Reset | kritisch | per-Sitter-State aus Boot | Re-Init via 90023 (QS_BOOT_RELOAD); `MY_SITTER` aus Sit-Status | ja |
| TC-009c | `[QS]sitB.lsl` Reset | kritisch | `MENU_LIST` aus Boot rekonstruiert | Re-Init via 90023 (QS_BOOT_RELOAD); `FIRST_INDEX`-Pose | ja |

## G. Neue Coverage

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-025 | Sitter denied `PERMISSION_TRIGGER_ANIMATION` | mittel | Pose stoppt, kein Hang | sitA gibt Sitter frei; `MY_SITTER == ""` | nein |
| TC-027 | Sit während Boot-Race (90098-Stream aktiv) | mittel | Pose-Default greift nach Boot | `boot_done == TRUE` vor erster Anim; kein verlorener Sit | ja |
| TC-028 | `[QS]hudprop` Auto-Attach bei Sit | mittel | HUD-Prop + Pose laufen | **deferred** — wartet auf QSALIVE LINK_SET-Layer (siehe MEMORY) | ja |

## H. Plugin removal during runtime

Exercises the `CHANGED_INVENTORY` removal-detection paths added in
sitB 0.9933+ (adjuster / faces / select), adjuster 0.9912+ (offset
LSD-mirror + self-reset), offset 0.9901+ (`qs:offset:alive` LSD flag),
and hudproxy 1.1902+ (`requireOffsetPlugin` gate). Each test removes
a plugin script from the sitter inventory **without** a manual reset,
then verifies the dependent UI / message path reacts on the next
interaction.

Section is intentionally English (touch-as-you-migrate convention);
older sections stay German until they're separately migrated.

| ID | Scenario | Risk | Expected | Pass criterion | Recovery |
|---|---|---|---|---|---|
| TC-040 | Remove `[QS]adjuster` → open ADJUST submenu | low | `[HELPER]` missing | sitB renders ADJUST without `[HELPER]` on first owner-touch after removal | no |
| TC-041 | Remove `[QS]faces` → open ADJUST submenu | low | `[FACES]` missing | sitB renders ADJUST without `[FACES]` | no |
| TC-042 | Remove `[QS]select` → trigger any select-driven path (sit + multi-slot menu) | medium | Routing falls back to non-select path | `select_present()` returns FALSE; no `[SELECT]`-driven dialog or branch | manual restart if state inconsistent |
| TC-043 | Remove `[QS]offset` → sitA `[ALL POSES]` / `[SAVE]` | low | `"Personal offset storage not installed - position not saved."` | RegionSayTo message exactly matches; no silent fail | no |
| TC-044 | Remove `[QS]offset` → HUD `+X` / `+Y` / `+Z` click | medium | `"The offset plugin is required to adjust positions."` | no visual move (90057 suppressed); no single-step ghost | no |
| TC-045 | Remove `[QS]offset` → HUD "RESET pose" | medium | Same message as TC-044; visual reset skipped | `resetPos` jumps past both 90262 sends and the 90057 reset | no |
| TC-046 | Remove `[QS]prop` → adjuster NEW → `[PROP]` | low | `"For this you need the prop plugin script."` | adjuster's `prop_present` FALSE after its own `llResetScript` on CHANGED_INVENTORY | no |
| TC-047 | Plugin re-added (drop adjuster back in) | low | Button reappears on next menu | HELLO on plugin's state_entry → flag flips TRUE → next ADJUST shows `[HELPER]` | no |
| TC-048 | Toggle plugin (remove → re-add) rapidly | medium | End state correct | One CHANGED_INVENTORY may coalesce both events; flag must reflect final state | no |
| TC-049 | Renamed plugin: `[FOO]adjuster` removed | medium | `[HELPER]` missing | `adjuster_script_name` captured `"[FOO]adjuster"` from HELLO id; inventory-probe finds `INVENTORY_NONE` | no |
| TC-050 | Plugin removed with ADJUST dialog still open, user clicks stale button | high | Clean fail or silent drop | No script crash; ideally a chat error; bad UX but acceptable | manual menu reopen |
| TC-051 | Plugin removed while user is sitting on slot | high | Clean unsit or active session continues | adjuster removal triggers `unsit_all()` + reset (Z.857-862); other plugins must not crash | re-sit |
| TC-052 | Multiple plugins removed simultaneously (multi-select delete) | medium | All cached flags clear in one CHANGED_INVENTORY tick | Single event probes all captured names; flags reflect post-removal state | no |
| TC-053 | Notecard re-save concurrent with plugin removal | medium | Boot's wipe + sitB's removal-probe both fire without ordering hazard | `qs:*` keys repopulate; `*_present` reflects post-event state | manual restart if seeds drift |
| TC-054 | Region restart with plugin already missing | low | Clean boot, no `[HELPER]` / `[FACES]` | All flags FALSE on state_entry; no HELLO from missing → stays FALSE | no |
| TC-055 | Sitter with only `[QS]sitA` + `[QS]sitB` (all plugins removed) | medium | Sit works; pose menu shows core buttons only | No `[HELPER]` / `[FACES]` / `[QUICKYHUD]` / `[PROP]` entries anywhere | no |

## I. Regressions-Smoke-Tests

Tests derived from recurring bug classes documented in MEMORY
conventions and the TODOLIST "Recently retired" log. Orthogonal to
A-H: each one covers a class of failure that has actually shipped to
users in past versions, not a coverage gap in plugin removal or sync
drift.

Section is English (touch-as-you-migrate convention), matching H.

| ID | Scenario | Risk | Expected | Pass criterion | Recovery |
|---|---|---|---|---|---|
| TC-056 | KeepNulls regression: dialog rendered from notecard with empty/null list elements | high | No crash, no off-by-one | No runtime error in owner chat; MENU_LIST contains no unintended `""` entries; clicks trigger expected actions | yes |
| TC-057 | Creator-rename pack `[QS]*` → `[FOO]*` end-to-end | high | All paths functional under renamed scripts | No literal `[QS]` in any chat / debug output; HELLO-driven plugin gates work; SYNC re-sync intact | yes |
| TC-058a | Web-DUMP: endpoint HTTP 500 mid-cascade | high | `dump_failed = TRUE`; failure line in chat | Exactly one `[DUMP] Upload failed — link may be incomplete.`; no `Done` line | yes |
| TC-058b | Web-DUMP: concurrent `[DUMP]` click during running cascade | high | Reject gate fires (boot 0.917+) | Second click → chat hint; `webkey` / `cache` / `qs_dump_pi` not overwritten | yes |
| TC-058c | Web-DUMP: mode routing (loud / quiet / multi-channel) | high | Endpoint + chat volume + `&n=` param match entry path | See § I.3 detail | yes |

### I.1 — TC-056 detail (KeepNulls regression)

Memory `feedback_lsl_parse_nulls.md` records this class as the root
cause of all recent dialog crashes — KeepNulls leaves empty list
elements that downstream indexing miscounts.

**Setup:** test furniture with three AVpos notecard variants, run
sequentially with `[QS]sitA` reset between each:

- V1 consecutive separators: `BUTTON foo||bar`
- V2 trailing empty: `MENU Top|`
- V3 leading empty: `MENU |Top|Sub`

`VERBOSE 3` in the AVpos notecard turns on per-script debug chatter via
the project-wide verbose ladder (see `qs:cfg:verbose`).

**Steps:** rez → wait `boot_done == TRUE` → sit → open `[ADJUST]` →
click every rendered button → trigger `[QS]debug.lsl` dump → inspect
MENU_LIST → reset sitA → next variant.

**Tooling:** `[QS]debug.lsl` dump (ground truth), viewer chat log for
runtime errors, optional `VERBOSE 3` build with `Out(3, …)` at each
parse site.

**Cadence:** every release. Highest reproduction history in the fork.

### I.2 — TC-057 detail (creator-rename pack)

Verifies the script-name probe migration (TODOLIST § "Recently
retired", spanning sitA 0.283-0.285, sitB 0.032-0.035, adjuster
0.043-0.912, select 0.022, faces 0.902) is complete end-to-end.

**Setup:** clean QS furniture template. Rename every script
`[QS]<name>` → `[FOO]<name>`: sitA, sitB ×N, boot, root, adjuster,
select, prop, faces. SCRIPT_CHANNEL suffix preserved
(`[FOO]sitA 0`, `[FOO]sitA 1`, …). AVpos notecard with ≥2 SITTER,
≥3 POSE, ≥1 SYNC, ≥1 SUBMENU.

**Steps:**
1. Cold boot; verify `boot_done == TRUE` via `[QS]debug.lsl`.
2. Self-check after 5s: no `"missing"` warnings; `qs:boot:asset` in
   LSD.
3. Two avatars sit; both receive default pose ≤1s.
4. Cycle every avatar through every pose.
5. SYNC pose on both, observe 5 min (reuses TC-021 method) — visually
   synchronous after re-acquisition.
6. ADJUST: X+/Y+/Z+, REFERENCE toggle, SAVE → LSD `qs:p:<ch>:<i>`
   appears.
7. Plugin gates: `[EXPRESSION]` / `[PROP]` / `[CAMERA]` present iff
   the corresponding `[FOO]*` script is in inventory.
8. HUD cross: ME / YOU / ALL via HUD → 90057 routing works.
9. DUMP via helper path → completes.
10. HUD sends 90271 → both re-sync without stand-up flicker.

**Pass:** no occurrence of literal `[QS]` in chat / debug output;
`select_present()` does not fall back to `[AV]select` while
`[FOO]select` is in inventory.

**Tooling:** pre-rename `Grep -n '"\[QS\]'` over all scripts; same
grep over post-test chat log — expect zero matches.

**Cadence:** once per release. Bulk-rename via viewer inventory is
cheap; biggest single migration in the fork deserves end-to-end check.

### I.3 — TC-058 detail (Web-DUMP failure modes)

Coverage for the quiet-mode surface added in boot 0.923 / adjuster
0.913 (TODOLIST top entry). Larger surface than the historical
loud-mode path.

#### TC-058a — Endpoint HTTP 500 mid-cascade

**Setup:** local `settings.php` copy on test webserver, modified to
return HTTP 500 for chunks N≥3 during a 5s window then 200. boot's
`dump_url()` helper pointed at the test URL (test build with override
constant, reverted after test).

**Steps:** enter adjuster via QuickyHUD pose menu
(QPP_CFG:ADJUSTMODE=On → quiet path) → `[HELPER]` → `[DUMP]` → open
live-view URL from chat in browser → observe.

**Pass:** browser shows content up to chunk 2, stalls at chunk 3;
after `$stall_seconds` browser displays stall-detector message; owner
chat at end: exactly one `[DUMP] Upload failed — link may be incomplete.`
line, no `Done` line.

#### TC-058b — Concurrent DUMP click (reject gate, boot 0.917+)

**Setup:** normal quiet-mode path, no endpoint tampering. Notecard
large enough for cascade ≥10s (≥3 SCRIPT_CHANNELs or ≥500 POSE lines).

**Steps:** click `[DUMP]` → within 2s click `[DUMP]` again → let first
cascade complete.

**Pass:** second click triggers owner-chat hint; live-view URL from
first click stays valid; final settings.php has one consistent webkey
end-to-end.

**Fail indicator:** two distinct live-view URLs, at least one
truncated.

#### TC-058c — Mode routing (loud vs quiet vs multi-channel)

**Setup:** three trigger paths, each on fresh furniture (or `[RESET]`
between).

*Path A — Loud (helper_mode=TRUE):* `[HELPER]` directly → `[DUMP]`.

*Path B — Quiet (helper_mode=FALSE, ADJUSTMODE=On):* QuickyHUD pose
menu with ADJUSTMODE=On → QPP_CFG path → `[DUMP]`.

*Path C — Multi-channel cascade:* notecard with ≥3 SITTER slots,
trigger quiet mode, verify mode flag persists across cascade
`msg>=1` re-emits.

**Pass A:** chat contains `--✄--COPY ABOVE--✄--` and
`--✄--COPY BELOW--✄--` banners; POST to `avsitter.com/settings.php`;
no `&n=` parameter in request body.

**Pass B:** chat has only `[DUMP] Live view: <url>` upfront then
`[DUMP] Done — link finalized.` at end (no per-line chat); POST to
`slquicky.com/quicky-sitter/dump/settings.php`; request body contains
`&n=<lines>` matching notecard line count; browser auto-refreshes
(HTTP `Refresh: 3`) until `.done` marker, then settles; live-view
header reads `"X lines uploaded — notecard had Y lines at boot time"`.

**Pass C:** single `webkey` across all channels; browser shows
continuous growth across channel boundary; exactly one `Done` chat
line at absolute end.

**Tooling:** browser DevTools network tab for POST inspection; owner
chat log diff between paths; `[QS]debug.lsl` for `dump_quiet` /
`dump_failed` flag state.

**Cadence:** mandatory on any change to `boot.lsl` `web()` /
`Readout_Say` / 90098 handler, or `adjuster.lsl` `[DUMP]` handler.
Skippable for pure QSALIVE / plugin changes.

---

## Mess-Methodik

- **Pose-Switch-Latenz.** UI-Klick-Timestamp bis `llGetAnimationList`
  neue Anim enthält. Toleranz <1 s.
- **State-Recovery-Zeit.** Event bis Pose wieder korrekt. <5 s
  (TC-005/006/011), <10 s (TC-008/020).
- **State-Inspektion.** `[QS]debug.lsl`-Dump als Ground Truth für
  LSD/`MENU_LIST`/`SITTERS`.
- **Visuelle Stabilität.** Frame-by-Frame-Review der Aufnahme — keine
  T-Pose-Frames zulässig außer wo explizit erwartet (TC-006).
