# Page-oriented pose-menu rebuild — implementation plan

**Status: WORKING DRAFT (not committed).** Built against the frozen
[`MENU_SPEC.md`](./MENU_SPEC.md) (commit e6e62bf). The spec is *what must not
break*; this plan is *how we get there*. Same discipline as the qs:alive
presence migration: **every section carries a failure-case proof**, because the
target (570 poses, 6 sitters) is too expensive to test by hand and correctness
must come from reasoning.

**Addressing decision (locked):** index addressing **with per-click
re-validate** (§ 5). Index gives the heap + CPU win; the re-validate read
restores the self-correction that the current name-based dispatch had for free.

`[verify]` = must be measured/confirmed in-world before that section is final.

---

## § 0 — Scope

**Changes:** only `[QS]sitB.lsl` (drop the `MENU_LIST` RAM list + its 5 uses)
and `[QS]boot.lsl` (write a small navigation sidecar + count key during seed).

**Unchanged:** the LSD pose store `qs:p:<ch>:<i>` (sitA reads it — do not touch
its field layout), all of MENU_SPEC § 7 external contracts, all of § 8
invariants, and `[QS]sitA.lsl` (sit-state / playback / adjust_pose_menu).

**Done when:** sitB RAM is `O(visible page + nav depth)` not `O(poses)`; 570
poses / 6 sitters renders + dispatches with no Stack-Heap-Collision; MENU_SPEC
MA-cases + the new stale-click/lock cases pass.

**Non-goals:** no marker-grammar change (MENU_SPEC § 1 stays), no sitA refactor,
no HUD-side change. A pose *limit* is explicitly **not** the deliverable — the
spec calls a limit a stopgap, not a foundation.

---

## § 1 — Storage model (LSD = truth)

**Unchanged — the pose entries** (sitA + boot + adjuster all read these):
```
qs:p:<ch>:<i> = name|type|anim|pos|rot      (i = flat seed index, MENU_SPEC § 1)
```

**NEW — navigation sidecar**, written by boot at seed (boot already walks the
list once, so this is free CPU). Two discriminated key families:

```
qs:nm:<ch>:<mi>  = childCount | parentMarkerIdx      (one per MENU marker, incl. synthetic root mi=-1)
qs:nt:<ch>:<ti>  = targetMarkerIdx                    (one per TOMENU button)
```

- `childCount` of marker `mi` = number of contiguous non-`M:` entries after it
  (= today's § 3 count loop, computed once). Render + paging math read this
  **O(1)** instead of walking (MENU_SPEC § 9 hotspot gone).
- `parentMarkerIdx` = the enclosing marker's index; **`[BACK]` reads it O(1)**
  instead of the backward-scan (MENU_SPEC § 4 / § 9 hotspot gone). Root
  (`mi=-1`) stores `parentMarkerIdx = -2` (sentinel: "[BACK] → select/none").
- `targetMarkerIdx` = the `M:Foo*` index a `T:Foo*` click navigates to —
  removes the name-pair `llListFindList` in dispatch (MENU_SPEC § 5 / sitB:756).

**NEW — count key:**
```
qs:cfg:slots:<ch> = <total entry count for this channel>
```
Replaces `llGetListLength(MENU_LIST)` (MENU_SPEC § 10.4 — confirmed absent today).

**NEW (conditional) — reverse map** for inbound name→index (§ 6):
```
qs:rn:<ch>:<name> = <flat index>            [verify LSD budget — see § 6/§ 14]
```

**Failure-case proof:** the sidecar/count/reverse keys are *derived* from
`qs:p:*`. On a notecard reseed boot **rewrites them synchronously before** the
90023/90024 broadcast that tells sitB to re-read — identical ordering to the
presence-wipe (clear+rewrite as strictly-ordered events, no clear-vs-read race).
A stale sidecar can therefore never be observed by a consumer: boot owns both
the data and its index, and writes the index last.

---

## § 2 — RAM model (the view-state block)

Everything sitB keeps in RAM after the rebuild. The point: it is a small,
**single-clearable block** (§ 7), `O(page + depth)`, with no list scaling in N.

| Var | Size | Replaces | Note |
|---|---|---|---|
| `page_map` | strided-2 `[label, flatIdx]`, ≤ ~12 entries | `MENU_LIST` slice | the only per-content RAM; rebuilt every render |
| `nav_stack` | list of marker indices, depth = menu nesting (typ. ≤ 4) | `current_menu` + `last_menu` | explicit path; `[BACK]` = pop; top = active marker |
| `menu_page` / `plugin_page` / `adjust_page` | int | same | paging cursors |
| `in_plugin_menu` / `in_adjust_menu` / `helper_mode` | int | same | mode flags |
| `ANIM_INDEX` / `FIRST_INDEX` | int | same | playing / default pose index (small) |
| `speed_index`, `MY_SITTER`, `CONTROLLER`, `menu_handle`, `input_locked` | small | same + § 7 | `input_locked` is new (§ 7) |
| `MTYPE/ETYPE/SET/SWAP/AMENU/…`, `QSPLUG_REGISTRY`, `ADJUST_MENU` | small / bounded | same | per-channel config from `qs:cfg` (unchanged) |

`nav_stack` top = active marker index (`-1` at root). `last_menu` is subsumed:
`[BACK]` pops the stack; the "pop to last_menu else parent-scan" branch
(MENU_SPEC § 4) collapses to a single `nav_stack` pop, with `parentMarkerIdx`
as the authority when the stack was entered non-linearly (e.g. a deep-link
`T:` from the HUD).

**Heap math:** today MENU_LIST ≈ 30 KB at 570. After: `page_map` ≈ 12 ×
(label + int + list overhead) ≈ < 1 KB, `nav_stack` ≈ depth ints. The transient
2× peak on insert (MENU_SPEC § 9 / sitB:1251) disappears because the list it
doubled no longer exists (§ 9).

---

## § 3 — Rendering (page from LSD, not from a RAM list)

`animation_menu` keeps its 3-list / 12-slot / `reorder_dialog_buttons` shape
(MENU_SPEC § 3 — the dialog layout is a contract). Only the *source* changes:

1. `mi = nav_stack top` (active marker; `-1` = root).
2. `total_items = childCount(mi)` — one `qs:nm` read (was the § 3 count loop).
3. Page slice: for `j` in `[mi+1 + menu_page*ipp .. mi+1 + menu_page*ipp + ipp)`,
   read `qs:p:<ch>:<j>` field 0, **stop early** if `j > mi + childCount`
   (end of this submenu's children — replaces the `jump end` on next-`M:`).
   Push `[displayLabel, j]` into `page_map`; strip the `T:`/`P:`/`B:` prefix for
   display exactly as today (sitB:348-354); no-prefix (SYNC) shown raw.
4. `submenu_info = qs_pose_data(mi) field 2` (one read; unchanged source) drives
   the `V`/`A`/`S` add-ins.
5. Control column (`menu_items2`) + header: **unchanged logic** — they read
   `ANIM_INDEX`/config, not `MENU_LIST`. The header's current-pose name comes
   from `qs_pose_data(ANIM_INDEX)` field 0 (index→label, one read; replaces
   sitB:226 `MENU_LIST[ANIM_INDEX]`).

Reads per render ≈ `2 + ipp` (sidecar + submenu_info + ≤12 page entries).
Renders are user-paced (one per click/page), so this is not a hot loop.

**Failure-case proof:**
- Out-of-range index → `qs_pose_data` already returns `""` (sitB:139-144) →
  early-stop; never throws. A `childCount` that disagrees with reality (e.g.
  mid-reseed) over-reads → empty string → harmless early-stop, never a wrong
  pose (label still comes from the entry, not the count).
- `select`-handoff branch (no poses / `<2`) and `[Sitter N]` header: unchanged
  (read config, not the list).

---

## § 4 — Navigation (explicit hierarchy, no scans)

| Action | Today (MENU_SPEC § 4) | Rebuild |
|---|---|---|
| Enter submenu (`T:Foo*` click) | findList `M:Foo*` → `current_menu` | `qs:nt:<ch>:<ti>` → push `targetMarkerIdx` to `nav_stack` |
| `[BACK]` | pop `last_menu` else backward-scan for enclosing `M:` | pop `nav_stack`; if stack underflows, use `parentMarkerIdx(mi)` |
| `[BACK]` at root (`mi=-1`) | 90009 → select if present | unchanged (`parentMarkerIdx=-2` sentinel) |
| Page | `menu_page` ± clamped | unchanged (clamp from `childCount`) |

**Failure-case proof:** a `T:` whose `targetMarkerIdx` is stale (reseed) is
caught by § 5 re-validate *before* the push (the `T:` label is re-checked at the
click index). `parentMarkerIdx` is boot-derived and rewritten-before-broadcast
(§ 1), so `[BACK]` can never climb into a freed index.

---

## § 5 — Dispatch + the index re-validate mechanism (the robustness core)

A click delivers a **label** (`llDialog` gives the button text). The page that
produced it is in `page_map` as `[label, flatIdx]`. Dispatch:

1. Find the clicked label's slot in `page_map` → `flatIdx`.
2. **Re-validate:** read `qs:p:<ch>:<flatIdx>` field 0. Compare its
   (prefix-stripped) label to the clicked label.
   - **Match** → act on `flatIdx` (play pose / push submenu / send button —
     by index, no scan).
   - **Mismatch** (data changed under the open dialog: reseed / insert / swap) →
     **do not act on the stale index**; re-render the current page and drop the
     click. This is the self-correction the name-based dispatch had implicitly;
     here it costs exactly one LSD read.
3. Control buttons (`[BACK]`/`[NEW]`/`[ADJUST]`/`[<<]`/`[STOP]`/…) are **not**
   in `page_map` → routed by literal compare exactly as today (they carry no
   index, so no re-validate needed).

This subsumes MENU_SPEC § 5's three routing layers unchanged in *order*
(`in_plugin_menu` → `in_adjust_menu` → MENU dispatch); only the third layer's
name→index `llListFindList` chain (sitB:740-793) becomes page_map + re-validate.

**Failure-case proof (the central one):**
- *Stale click after reseed:* old page_map index `k` now holds a different pose.
  Re-validate reads `k`'s label ≠ clicked label → re-render, no wrong pose
  played. ✔ (This is the case index addressing would otherwise get wrong — it's
  why we chose re-validate over pure-index.)
- *Stale click after insert (90300):* indices ≥ insert_at shifted by 1. Either
  the click is re-validated against the shifted data (mismatch → re-render) or,
  if § 9 also shifts `page_map` live, it matches the right entry. Both safe;
  never a silent wrong pose.
- *B: button:* re-validate confirms the `B:` label at `flatIdx` before reading
  its field-2 channel data (MENU_SPEC § 14) → never sends an old button's
  channel payload after a reseed.
- *Empty read* (`flatIdx` now past end) → mismatch → re-render. ✔

---

## § 6 — Inbound name→index (the one genuine reverse lookup)

The only `MENU_LIST` use that is **not** index-driven: inbound 90000/90003/
90008/90010 carry a pose **name**; sitB resolves it to `ANIM_INDEX`
(sitB:1011-1018) to drive the header, SYNC reset, and `send_anim_info` (which
needs the index to read pos/rot from LSD). This is on the **hot path** — a pose
click round-trips as a self-echo (sitB:749 `llMessageLinked(LINK_THIS,90000,…)`
is received by sitB in the same prim and is what actually sets `ANIM_INDEX`
today). So an O(n) LSD scan per play is too slow at 570.

**Plan (two-tier):**
1. **Self-originated plays — set the index directly.** When sitB dispatches a
   pose click (§ 5) it already holds `flatIdx`. Set `ANIM_INDEX = flatIdx` at
   dispatch and make the self-echo idempotent (the echo's name→index becomes a
   no-op confirm, or is skipped when `two==SCRIPT_CHANNEL` and the index already
   matches). Removes the reverse lookup from the **dominant** path entirely.
2. **External / cross-sitter SYNC name-only plays** (stock plugins, 90008 to
   "all sitters that have it"): resolve via the reverse map
   `qs:rn:<ch>:<name>` (§ 1) — **O(1)**. boot writes it at seed.
   - *Budget gate* `[verify]`: pose data is **per-channel distinct, not
     duplicated** (confirmed: boot resets `seed_count` on each `SITTER`
     directive, boot:164-178/378-382 — each channel indexes its own poses from
     0). So total LSD = **Σ per-channel pose counts**, and the reverse map adds
     ~1 (smaller) key per pose — roughly doubling the *key count*, not the byte
     bulk. Measure the real 570/6 set; if it doesn't fit, fall back to a
     **bounded scan** (read `qs:p` sequentially, stop at first match or
     `childCount`-capped window) — acceptable because tier 1 already removed the
     hot self-echo, so tier 2 fires only on genuinely external sends, which are
     rare.

**Failure-case proof:**
- *Reverse map stale after reseed:* boot rewrites it before broadcast (§ 1); and
  the consumer of `ANIM_INDEX` (send_anim_info) reads pos/rot by that index from
  the *same* freshly-written `qs:p` generation → consistent.
- *Name not present* (SYNC pose this sitter lacks): reverse-map miss → `index=-1`
  → existing guard `(index != -1 || msg == "")` (sitB:1028) already handles it →
  pose not played on this sitter. ✔ (matches stock SYNC semantics)
- *index→label uses elsewhere* (ETYPE==2 check sitB:1037; SYNC reset sitB:1050)
  already hold the index → one `qs_pose_data` read replaces `MENU_LIST[idx]`. ✔

---

## § 7 — invalidate-on-async-change + input lock (MENU_SPEC § 13)

One routine, `invalidate_view()`, called by every async mutator:

```
invalidate_view():
    nav_stack = [-1]            # back to root
    menu_page = 0
    in_plugin_menu = in_adjust_menu = FALSE
    helper_mode    = (preserve per existing standup/swap rules)   # see table
    page_map       = []
    llListenRemove(menu_handle); menu_handle = -1
    input_locked   = TRUE       # cleared on next render
```

`input_locked` gate at the top of `listen()`: while set, **drop** menu clicks
(they can't act on a half-mutated state). Cleared when the next render runs
(`animation_menu(0)` opens the fresh dialog). This closes the click-race the
listen-remove only partially covered (MENU_SPEC § 12.3).

**Trigger table (maps MENU_SPEC § 13 gaps → fixed):**

| Async event | Today's partial reset | Rebuild |
|---|---|---|
| SWAP 90031 (quiet) | listen-remove + CONTROLLER/MY_SITTER="" | `invalidate_view()` (adds current_menu/helper/in_* reset + lock) — closes § 12 stale view-state |
| SWAP 90030 (loud) | none (reopens) | `invalidate_view()` then reopen at root |
| Reseed 90024→90023 | current_menu/page=0 + list reload | `invalidate_view()` + re-read sidecar/count (adds in_*/helper/listen reset — § 13 gap) |
| Stand-up CHANGED_LINK | MY_SITTER="", ANIM_INDEX=FIRST, helper off | `invalidate_view()` (adds current_menu/paging/in_* reset) |
| Live insert 90300 | SHIFT indices | § 9 (shift, not full invalidate — view stays open) |

**helper_mode caveat:** standup/swap clear it (occupant changed); a *reseed* with
the same occupant must **preserve** helper_mode/qh_on (the user is still
adjusting). So `invalidate_view()` takes a `keep_mode` flag rather than blindly
clearing — reseed passes `keep_mode=TRUE`, swap/standup `FALSE`. (This mirrors
the existing OLD_HELPER_METHOD branch at standup, MENU_SPEC § 6.)

**Failure-case proof:** after any trigger, the next click is either dropped
(`input_locked`) or hits a freshly-rendered page whose `page_map` was rebuilt
from current LSD → § 5 re-validate guarantees correctness even if the lock is
somehow bypassed. Defense in depth: lock (drop) **and** re-validate (verify).

---

## § 8 — boot-side changes

During seed (boot already parses the notecard into `qs:p:*`):
1. Track, per entry, the enclosing marker → emit `qs:nm:<ch>:<mi>` (childCount,
   parentMarkerIdx) and `qs:nt:<ch>:<ti>` (targetMarkerIdx via the name-pair,
   resolved in the same single pass with a small open-marker stack).
2. Emit `qs:cfg:slots:<ch>`.
3. (Conditional) emit `qs:rn:<ch>:<name>` (§ 6) — budget permitting.
4. On reseed: wipe `qs:nm:/qs:nt:/qs:rn:` for the channel, rewrite, **then**
   broadcast 90023/90024 (ordering = § 1 proof).

This is the `seed_names` walk boot already does (see memory:
project_boot_seed_names_optimization) — the sidecar is computed in the same
pass, so the marginal boot cost is a handful of extra LSD writes, not a second
traversal.

**Failure-case proof:** boot is the sole writer (no concurrent producer for
these keys), so no write-write race. A crash mid-write leaves a short channel;
the count key written *last* bounds all readers, so a half-written sidecar is
never indexed past its valid prefix.

---

## § 9 — NEW / live insert (90300) as an LSD re-key

Today (MENU_SPEC § 13 / sitB:1251): `MENU_LIST = llListInsertList(...)` →
transient 2× of a 30 KB list → the heap crash. Rebuild:

1. Shift LSD entries: for `j` from `last` downto `insert_at`,
   `qs:p:<ch>:<j+1> = qs:p:<ch>:<j>`; write the new entry at `insert_at`.
2. Bump `qs:cfg:slots:<ch>`; update affected `qs:nm` childCounts +
   `parentMarkerIdx`/`targetMarkerIdx` that were ≥ insert_at (the same `++` the
   current code does to `current_menu/last_menu/FIRST_INDEX/ANIM_INDEX`,
   MENU_SPEC § 13 — now applied to sidecar values and `nav_stack`/`ANIM_INDEX`).
3. Live view: shift `page_map` flatIdx ≥ insert_at and `nav_stack` entries ≥
   insert_at by 1; re-render. **No RAM list to double → no 2× peak.**

**Failure-case proof:** the LSD shift is O(entries-after-insert) writes but **no
list lives in RAM**, so peak heap is one entry, not 2×N. If the shift is
interrupted, the count key (bumped last) still bounds readers; worst case the
user re-saves. A stale click during the shift is caught by § 5 re-validate.
*Cost note:* a single-entry insert near the front is O(N) LSD writes — acceptable
for an editor action (rare, user-paced); a bulk re-key would instead trigger a
full reseed.

---

## § 10 — External-contract preservation (MENU_SPEC § 7 — byte-identical)

| Contract | Preserved how |
|---|---|
| Inbound 90000/03/08/10 (name) | § 6 resolves name→index; same guards (sitB:1028), same `send_anim_info` |
| 90004/90005 re-menu | unchanged (re-render from LSD) |
| 90030/90031 swap | § 7 `invalidate_view()` + the 90031 listen-teardown / 90030-asymmetry kept (MENU_SPEC § 12) |
| 90045 pose-played / SYNC OLD_SYNC | index→label read; reset logic unchanged |
| 90050/90051/90055/90100/90101/90009 (outbound) | emitted identically; dispatch still produces them (MENU_SPEC § 11/§ 14) |
| 90077/90078 self-check, 90097 count, 90201-203 caps | untouched (don't use MENU_LIST) |
| 90212 QSPLUG_REGISTER, ADJUST_MENU | untouched (own RAM, small) |
| 90300/90023/90024 | § 9 / § 7 |
| AVpos notecard grammar | boot parse unchanged (MENU_SPEC § 1); sidecar is additive |

**Net:** no wire-format changes. Plugins, HUD, sitA, select see identical
messages. The rebuild is sitB-internal + additive boot LSD keys.

---

## § 11 — Invariant preservation (MENU_SPEC § 8)

| Invariant | Preserved |
|---|---|
| ANIM_INDEX/FIRST_INDEX as flat indices; standup→FIRST | unchanged (small ints) |
| SYNC (no-prefix, OLD_SYNC reset) | § 6 name compare unchanged |
| Multi-sitter slot filter (data[0]==SCRIPT_CHANNEL/"X") | unchanged (per-channel keys `:<ch>:`) |
| RLV `[STOP]`/`Control...` gating + "Menu for" header | unchanged (reads config/ANIM_INDEX) |
| CHANGED_LINK pre-boot eject / standup / perm-revoke ordering | unchanged + `invalidate_view()` (§ 7) |
| MTYPE/ETYPE value matrix (MENU_SPEC § 14) | unchanged branches; index→label reads where needed |
| Owner-gate on `[HELPER]`/`[QUICKYHUD]` | unchanged (sitB:1133 + adjuster:726) |

---

## § 12 — Rollout / phasing (incremental, each step testable)

1. **boot sidecar (additive, dormant).** Write `qs:nm/qs:nt/qs:cfg:slots`
   (+ optional `qs:rn`). sitB still uses MENU_LIST. Ship + verify keys exist,
   nothing else changes. *Reversible.*
2. **sitB read-path swap.** Render + total_items + [BACK] + dispatch read the
   sidecar/page_map instead of MENU_LIST; keep MENU_LIST built in parallel as an
   assertion oracle behind `bDebug` (compare index results) for one release.
3. **Drop MENU_LIST build** (the seed loop sitB:426-439) once step 2 is
   confirmed. This is where the heap is actually reclaimed.
4. **§ 7 invalidate + lock**, **§ 6 self-echo opt**, **§ 9 re-key insert** —
   each independently shippable behind the now-stable read path.

Version bumps +0.0001 per file per touch; sitB + boot move together where a
step spans both. No flag-day: steps 1-2 are additive/parallel; the only
behaviour-visible step is 3 (RAM drop) and 7-features.

---

## § 13 — Test mapping

- Reuse MENU_SPEC MA-cases / TESTPLAN § J for contract parity.
- **New cases (the rebuild's raison d'être):**
  - T-PAGE: 570 poses, page through a 200-child submenu — no heap error, correct
    labels per page.
  - T-REVAL: open pose dialog → reseed (edit notecard) → click a now-moved
    button → asserts re-render, **no wrong pose** (§ 5).
  - T-SWAP-STALE: HUD quick-swap (90031) with pose dialog open → click → asserts
    dropped (input_locked), new occupant opens at root (§ 7).
  - T-INSERT: `[NEW]` at 570 poses → no 2× heap peak; inserted pose addressable;
    open dialog's other buttons still hit correct poses (§ 9).
  - T-SYNC-EXT: external 90008 SYNC by name → plays on sitters that have it,
    skipped on those that don't (§ 6).

---

## § 14 — Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| LSD byte budget = Σ per-channel poses + reverse-map keys | **medium** `[verify]` | Duplication ruled out (per-channel distinct, confirmed § 6); reverse-map ≈ +1 small key/pose; measure real 570/6 set; bounded-scan fallback if tight |
| Re-validate read on every dispatch click | low | clicks are user-paced; 1 read each; far cheaper than today's O(n) findList chain |
| Self-echo opt changes ANIM_INDEX timing (§ 6) | medium | keep echo idempotent; assertion-oracle (§ 12.2) compares old vs new index for one release |
| Insert O(N) LSD writes near front (§ 9) | low | editor action, rare; bulk → full reseed |
| nav_stack vs parentMarkerIdx divergence on HUD deep-link | medium | parentMarkerIdx is the authority on stack underflow (§ 4); re-validate guards the entry |
| boot reseed ordering | low | wipe→rewrite→broadcast, count-key last (§ 1/§ 8 proof) — same pattern as presence migration |

---

## Open `[verify]` before code

1. **LSD budget** = Σ per-channel pose counts on the real 570/6 set (duplication
   already ruled out — per-channel distinct, § 6). Decides whether the § 6
   reverse map fits or we use the bounded-scan fallback. *(measure in-world)*
2. Self-echo frequency / exact `two==SCRIPT_CHANNEL` semantics on the 90000
   round-trip (confirms § 6 tier-1 removes the hot path).
3. In-world stale-view-state checks inherited from MENU_SPEC § 12/§ 13
   (reseed/swap/standup with a dialog open) — now covered by § 7, to be
   confirmed by T-REVAL / T-SWAP-STALE.
