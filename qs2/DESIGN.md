# QuickySitter v2 engine, design draft

**Status: exploratory.** Not part of any release, not scheduled, no code in this
folder yet. This is the accumulated reasoning from the design sessions of
2026-07-27 and 2026-07-28, written down so the thread survives.

Everything marked **measured** comes from the reference furniture (see
Measurement basis). Everything else is derived from the code or from LSL
semantics and is flagged as such. Nothing here has been reproduced in-world.

Related prior record: the Google Doc "QuickySitter: SET, Stations, and a
From-Zero Seat Model" (2026-07-27) covers sections 4 and 5 in an earlier form.

---

## 1. The problem, in two independent redundancies

### 1.1 Per-SITTER duplication in the notecard

A classic AVpos repeats the whole menu skeleton once per `SITTER` block. This
costs twice:

* **Notecard size.** This is the practical cause of hitting the viewer's
  notecard editor limit (~48 KB in the observed case, not the 64 KiB asset
  limit).
* **Storage.** The duplicates land one to one in LSD as `qs:p:<n>:*`,
  `qs:nm:<n>:*`, `qs:nt:<n>:*`. On the reference sofa: `Storage=73183` of
  131072 (**measured**). A single piece of furniture occupies more than half
  the linkset budget, and a large share of that is four copies of the same
  menu tree.

The second point is what makes the older "several pieces of furniture in one
linkset" idea unrealistic today. As long as one sofa eats 73 KB, no second one
fits beside it.

### 1.2 Per-seat bytecode duplication in the runtime

`sitA` and `sitB` are the only scripts that derive `SCRIPT_CHANNEL` from the
script name ([sitA.lsl:706], [sitB.lsl:747]) and are therefore the only ones
instantiated per seat. Everything else (`faces`, `prop`, `offset`, `select`,
`sequence`, `root-RLV`) is already a singleton that reads the channel as data.

Both per-seat scripts are **bytecode bound, not data bound**. Cross-check
against the project's own rule of thumb of ~50 bytes per line of real code:

| Script | code lines | predicted | measured used |
|---|---|---|---|
| `sitA` | 1187 | ~59400 | 59824 |
| `sitB` | 1085 | ~54250 | 51320 |

The RAM globals are all seat sized or page sized (`SITTERS`, `GENDERS`,
`SITTARGETS`, `page_map`, `nav_stack`); the pose data itself lives in LSD and is
fetched one entry at a time via `qs_pose_data()`. Nothing grows with pose count.

Consequence: a four seater pays for **four copies of the same program**, not for
four copies of data. 4 x 111 KB = 444 KB of sim script memory (**measured**
basis, arithmetic ours).

### 1.3 The two are independent

Neither requires the other. The singleton split works with today's integer slot
addressing; the new notecard format works on today's 2N+1 runtime. They can
ship separately and be rolled back separately.

---

## 2. Target runtime architecture

```
[QS]boot  +  [QS]station  +  [QS]menu  +  N x [QS]anim
```

| Script | Instances | Responsibility |
|---|---|---|
| `boot` | 1 | Notecard to LSD, as today |
| `station` | 1 | Prim binding, sit targets, occupancy table, pose selection, offsets, swap, camera |
| `menu` | 1 | Dialog rendering and dispatch, plugin registry, HUD wire |
| `anim` | N | Holds `PERMISSION_TRIGGER_ANIMATION` for its occupant. Starts and stops animations on request. Nothing else. |

The name `[QS]station` predates the `ITEM` naming and is under review; see
[FORMAT.md](FORMAT.md) open point 4.

### Why not fewer scripts

`station` and `menu` cannot be one script. That fails on exactly the arithmetic
that kills the "merge sitA and sitB per seat" idea: 59824 + 51320 = 111144
against a 65536 limit, **45608 bytes over** (**measured** inputs). The split is
forced by the byte ceiling, not chosen for tidiness.

The goal is therefore not "as few scripts as possible" but **as few instances of
the same bytecode as possible**.

### Why the per-seat script cannot be removed entirely

See section 3.

### Projected sim memory

Estimated, since the `anim` size is not yet built. Assumes `llSetMemoryLimit`
is actually called (see section 8).

| | today (measured) | target (estimated) |
|---|---|---|
| Four seater | 4 x 111 KB = 444 KB | 60 + 51 + 4x8 = 143 KB |
| Eight seater | 889 KB | 60 + 51 + 8x8 = 175 KB |

The ratio improves with seat count: factor 3 at four seats, factor 5 at eight.

---

## 3. Rejected: one script cycling permissions

The tempting version of this design has no per-seat script at all: a single
script requests `PERMISSION_TRIGGER_ANIMATION` from each occupant in turn.
**This is rejected**, on API semantics rather than on performance.

Today's synchronisation works because permission is acquired **once on sit** and
then held for the whole session ([sitA.lsl:1023]), so a `SYNC` costs each
instance nothing but a flag test ([sitA.lsl:490]) followed by
`llStartAnimation`. All N scripts receive the link message in the same sim frame
and fire in the same or the adjacent frame. The jitter is small and undirected.

With one script, three things break:

1. **The offset is permanent, not a stutter.** `run_time_permissions` is an
   event, so each seat costs an event round trip, at minimum one sim frame,
   and the order is deterministic rather than random. SL has no "start at time
   T", so two looping animations started 45 ms apart stay 45 ms out of phase
   forever. That is precisely what `SYNC` exists to prevent.
2. **Requesting for the next avatar revokes the previous one.**
   `llGetPermissionsKey()` is single valued. The running animation does not
   stop, but it can no longer be stopped, so a pose *change* costs a round trip
   per seat for the stop as well as for the start. Pose change is the most
   frequent operation there is.
3. **Race during cycling.** If someone stands up while the loop is at seat 3,
   the script animates against an avatar that is gone. Not an issue today,
   because each script only knows its own occupant and loses permission on
   standup anyway.

The constant (one frame or more) would have to be measured in-world. The
ordering is structural and cannot be optimised away, and for `SYNC` the ordering
is what matters.

Supporting evidence: AVsitter uses 2N+1 scripts precisely because of this
limitation. If cycling worked, it would have been done in 2015.

---

## 4. Notecard format

**The syntax lives in [FORMAT.md](FORMAT.md)**, which is the single source of
truth for tokens and parser rules. This section records only the ideas behind
it, so the two documents cannot drift.

The unit of furniture is called `ITEM` (named by the product owner on
2026-07-28; earlier drafts and the Google Doc say "station").

### 4.1 What changes conceptually

* **A pose is one line, not a name repeated across blocks.** Coupling becomes
  structural: whoever appears in the line takes part, whoever does not is not
  touched. Independence is the default, coupling the special case. The
  `POSE` versus `SYNC` distinction disappears.
* **The menu exists once per item, not once per seat.** This is the fix for
  1.1.
* **Seats have names.** `Links` exists only inside `Bett`. The address of an
  occupant is the pair `Bett/Links`, which is at the same time the LSD key and
  the address plugins use. Today's `SCRIPT_CHANNEL`, which is simultaneously
  slot index, LSD namespace, script name suffix and message filter, collapses
  into a single name.
* **The parent menu button is implicit.** `TOMENU` disappears, removing the
  most reported "my menu does not appear" failure.

### 4.2 Prim binding

An item binds by default to every prim carrying its name; `PRIM` on a `SEAT` is
the override for the ambiguous multi seat case. Prim name and prim description
are the only rez stable and relink stable identifiers available, unlike link
numbers and prim UUIDs.

`SET` is not removed, it cannot arise in the first place: two independent pieces
of furniture in one linkset are two items, isolated by construction because the
storage namespace is `qs:<item>:...` instead of `qs:*:<slot>`.

### 4.3 Position data

**One frame of reference.** If a seat owns exactly one prim, the only sensible
answer is that the offset is local to that seat's prim. That removes the
`LROT` / `REFERENCE` token and the inter frame conversion in `set_sittarget()`
([sitA.lsl:445]), and it makes "does my pose move if I relink" answerable with
a plain no.

Both the pose name and the seat name become resolvable, so a typo is a parse
error with a line number instead of the silent no-op it is today
([boot.lsl:1426], [boot.lsl:1427]).

Personal offsets inherit the address unchanged: `QSO:<user>:<slot>:<pose>`
becomes `QSO:<user>:<item>/<seat>:<pose>`. The `M#T!` all-poses fallback stays a
reserved pose name in the same key shape.

This block is the largest part of a real notecard and is entirely machine
written, which makes it the first candidate to live only in LSD and appear in
the notecard as export only.

---

## 5. Migration from classic AVpos

**Claim: fully automatic, no manual step.** This reverses an earlier assessment
that prim binding and menu divergence would need hand work.

### 5.1 The six assumptions that make it total

1. One legacy file becomes exactly **one** item. A classic AVpos describes
   one piece of furniture by definition.
2. **No `PRIM` lines are emitted.** The fallback rule "no binding given, assign
   seats in link order" reproduces today's `sittargets()` behaviour exactly.
   Pinned objects keep working through the retained legacy `#<a>-<b>` desc
   parser. The converter therefore never needs to see the linkset.
3. `SYNC` of the same name across blocks becomes one line naming all
   participating seats. `POSE` always becomes a line with exactly one seat.
4. Label collisions get internal IDs, the display label is preserved.
5. Menu tree is the **union**, ordered by `SITTER 0` with unseen entries
   appended in first-appearance order. Visibility is derived: a pose is offered
   to a seat if and only if that seat appears in the pose line.
6. Per-sitter configuration (camera, MTYPE/ETYPE, gender) moves to the seat.
   Hoisting to the item where all seats agree is optional cosmetics.

### 5.2 The trap that assumption 3 and 4 defuse

Coupling in the old format is **the token, not the name**
([sitB.lsl:933]): `POSE` dispatches with `channel = SCRIPT_CHANNEL` (own slot
only), `SYNC` with `channel = ""` (broadcast). So `POSE Sitzen|animA` in
sitter 0 and `POSE Sitzen|animB` in sitter 1 are two independent poses that
merely share a label. A converter grouping by label would silently couple them,
and the partner would stand up when you sit down. Pose identity in the new
format must therefore be the pair (label, seat set), not the label alone. This
propagates into the `OFFSETS` block, which addresses by ID rather than by
display name.

`SEQUENCE` follows the same rule.

### 5.3 Residual risk, not resolvable by assumption

The same pose under **different menu paths** in different sitter blocks. The
union then shows it under both. Mechanically detectable and reportable, but not
resolvable without allowing per-seat paths.

### 5.4 Consequence for sequencing

`boot` has **8220 bytes free** on the reference furniture (**measured**). At
~50 bytes per line of code that is room for roughly 160 lines, which is not
enough for a second notecard dialect. So the choice is:

* **Runtime first.** The singleton split removes code from sitA/sitB and leaves
  boot untouched, but builds the runtime against a format that is then replaced.
* **Format first, with an offline converter** (preferred). `boot` learns only
  the new dialect; legacy files are converted ahead of time in the
  `quicky-web-tools` path that already exists for DUMP. Costs boot nothing, but
  existing customers must run their notecard through a tool once. That is a
  support question, not a technical one.
* **Format first, with a dual parser in boot.** Seamless for customers, but
  someone has to show the 8220 bytes are enough first.

The preferred option depends directly on section 5 holding: **if conversion is
genuinely fully automatic, the dual parser is unnecessary** and legacy support
moves out of the furniture into a tool, where bytes are free.

---

## 6. Block inventory of the current scripts

Line counts are function boundaries; `link_message` blocks are attributed by
handled message number and are therefore rougher. The last column is the one
that matters.

### 6.1 `[QS]sitA`, 1629 lines

| Block | Where | ~Lines | Per seat? | Target |
|---|---|---|---|---|
| Boot and config | globals, `qs_load_from_lsd()` 140-284, 90024/90023 | 250 | no | `station` |
| Sit targets | `sittargets()` 324-399, `set_sittarget()` 430-463, `primcount_error()`, `IsInteger()`, desc parsing | 130 | no | `station`, shrinks |
| Occupancy and lifecycle | `changed()` 1252-1557, `release_sitter()`, `end_sitter()`, `run_time_permissions()` 1558-1629, 90060/90065/90070 | 430 | **partly** | split |
| Play animation | `apply_current_anim()` 528-593, `update_current_anim_name()`, `sit_using_prim_params()`, `is_sync_pose()`, `do_resync_tick()`, `timer()` | 190 | **only the start/stop calls** | split |
| Personal offsets | `lookup_personal_offset()`, `dialog()`, `adjust_pose_menu()`, `listen()` 776-888, 90260/90265/90263 | 300 | no | `station` or `offset` plugin |
| Swap | 90030/90031 | 80 | no | `station`, becomes a table swap |
| Inter instance protocol | 90045 broadcast, 90150, 90070, 90055/56/57, `SITTERS` replication, `one == SCRIPT_CHANNEL` checks | 180 | no | **disappears** |
| Legacy and debug | 90075/90076 (`OLD_HELPER_METHOD`), `OLD_SYNC`, `HASKEYFRAME`, 90298, 90011/90033/90001/90002 | 90 | no | product decision |
| Camera | 90202, `llSetLinkCamera` | 15 | no | `station` |

The two giants are `changed()` at 306 lines and `link_message()` at 363,
together 41% of the file.

### 6.2 `[QS]sitB`, 1643 lines

| Block | Where | ~Lines | Per seat? | Target |
|---|---|---|---|---|
| Menu rendering | `animation_menu()` 246-468, `reorder_dialog_buttons()`, `qs_pose_data()`, `page_map`/`nav_stack` | 260 | no, but needs **per operator state** | `menu` |
| Dialog dispatch | `listen()` 768-1076 | 309 | no, same | `menu` |
| Adjust UI | `adjust_dialog()` 644-738, `adjust_allowed()`, `in_adjust_menu` branch, QSADJ_REGISTER/UNREGISTER, `ADJUST_DYN`/`ADJUST_MENU` | 270 | no | `menu`, or dropped |
| Plugin registry | `plugin_dialog()` 573-625, QSPLUG_REGISTER, 90201/90202/90203 | 120 | no | `menu` |
| Pose dispatch | 90000/90050/90005, POSE vs SYNC decision, `send_anim_info()`, 90045 receive, 90055 | 150 | no | `station`, shrinks |
| Boot and config | `qs_load_from_lsd()` 507-572, QS_BOOT_WIPE/RELOAD, QSALIVE, `memory()` | 120 | no | **merges with 6.1 row 1** |
| Menu sidecar index | `qs_rebuild_sidecar()` 469-506, writes `qs:nm`/`qs:nt` | 38 | no | `boot`, built once per item |
| Security and access | `changed()` 1077-1141, `llUnSit`, `has_security`, `select_present()`, `rlv_present()` | 90 | no | `station` |
| HUD wire | 90100/90101, 90271 re-sync, 90299/90300/90301 | 120 | no | `menu` |

The giant here is `link_message()` at 502 lines, 31% of the file on its own.

### 6.3 What the inventory shows

**The mandatory per-seat part is tiny.** `run_time_permissions`, the permission
request in the `changed()` branch, and the `llStartAnimation` /
`llStopAnimation` calls in `apply_current_anim`, `do_resync_tick`, `end_sitter`
and `release_sitter`. Roughly **40 to 60 lines out of 3272**. Everything else in
both files can be a singleton.

That is the justification for the whole rebuild: today 3272 lines of bytecode
are instantiated N times so that 50 of them can exist N times.

**Three blocks vanish or shrink without anyone losing a feature:**

* Inter instance protocol in sitA, ~180 lines, no replacement needed.
* **Boot and config exists twice**, once in sitA and once in sitB, both reading
  `qs:cfg`. Together 370 lines for one job.
* The sidecar index is rebuilt **per sitter** today. With the v2 format, once
  per piece of furniture.

**One block carries the risk:** menu rendering plus dialog dispatch, 570 lines
that implicitly assume exactly one operator. `sitB` gets that for free today
because there is one instance per seat. A singleton needs explicit per operator
state (page, `nav_stack`, listen handle, channel). This is the only part of the
split that is new logic rather than moved logic, and the HUD side has a known
precedent: the per operator race in the hudproxy migration was deliberately
left open there, which would no longer be an option here.

---

## 7. Presence and counting

Two mechanisms that are easily conflated. Only one of them breaks.

### 7.1 Plugin presence is unaffected

`qs:alive:<name>` plus the boot CENSUS (90079) is LSD based and therefore
instance independent. The `menu` singleton reads exactly the same keys `sitB`
reads today. The split changes nothing here.

Two name probes do survive as fallbacks in `sitB`:

```lsl
integer select_present()  { ... || llGetInventoryType("[AV]select")   == INVENTORY_SCRIPT; }
integer rlv_present()     { ... || llGetInventoryType("[AV]root-RLV") == INVENTORY_SCRIPT; }
```

These are deliberate: stock AVsitter furniture has no QS broadcaster to write
`qs:alive`, so the flag alone would never fire. In v2 they are not a technical
question but a product one, tied to whether v2 keeps stock AVsitter
compatibility. If that is dropped, the fallbacks go with it.

### 7.2 The probe that does break

```lsl
integer get_number_of_scripts()          // [QS]sitA.lsl:285
{
    integer i;
    while (llGetInventoryType(main_script + " " + (string)(++i)) == INVENTORY_SCRIPT)
        ;
    return i;
}
```

This counts `[QS]sitA 1`, `[QS]sitA 2`, ... and is the **canonical seat count**
([sitA.lsl:660]), travelling to `sitB` as field 2 of the QSALIVE 90097 payload,
where it drives swap and select gating as `number_of_sitters`
([sitB.lsl:386]).

In v2 there is no `sitA <n>` left to count. The seat count comes from the
notecard via LSD, which is where it belongs. This is strictly better than today:
a forgotten `[QS]sitA 3` currently shrinks the furniture silently, whereas a
declared-seats versus present-animators mismatch is detectable and reportable.

### 7.3 How `station` learns about its animators

Per the project convention: **they announce, they are not probed.** Either a
`qs:alive:anim:*` flag or a census reply, the same pattern the plugins already
use. Never `llGetInventoryType("[QS]anim 3")`.

### 7.4 Consequence: animators need no name suffix

Permission is bound to the avatar, not to the prim, so `llStartAnimation` does
not care which animator serves which seat. The only real constraint is that the
animations must live in the same prim as the animator script, and the QS scripts
all sit in one prim anyway.

The N animators are therefore **interchangeable and anonymous**. `station`
assigns seats at runtime and addresses each animator by the handle it reports
itself (`llGetScriptName()`), not by an index someone derives from a name. The
creator drops N identical copies and is done.

This removes the last name-derived identity in the system, `SCRIPT_CHANNEL`
parsed out of the script name ([sitA.lsl:706], [sitB.lsl:747]). That is exactly
what the convention has been arguing against since the RLV rename broke the old
`[AV]root-RLV` name probe.

---

## 8. Open questions and measurements needed

| # | Question | Blocks what |
|---|---|---|
| 1 | Real size of `[QS]anim`. Estimated at 8 KB from ~150 lines; unverified. | The whole memory projection in section 2 |
| 2 | `llSetMemoryLimit` appears in **no** script in the repo. Without it every instance books the full 64 KB and the projection is void. Needs a peak measurement per script plus headroom, otherwise stack-heap collisions. | Section 2, and it is a win available today without any rebuild |
| 3 | Per operator dialog state in a singleton `menu`. Design, not measurement. | Section 6.3 |
| 4 | Collision rate in the existing stock: how often do identically named `POSE` entries occur across sitter blocks. This is the only place a naive converter breaks. | Section 5, and therefore the sequencing choice in 5.4 |
| 5 | LSD budget after de-duplication. Re-measure `Storage=` on the reference sofa with a converted notecard. | The "several pieces of furniture in one linkset" goal |
| 6 | Does v2 keep stock AVsitter compatibility. Product decision, not technical. | The `select_present()` / `rlv_present()` name-probe fallbacks in 7.1, and the legacy blocks in 6.1 |

Question 4 is the key one for the whole rebuild, not a side issue: it decides
whether legacy support can leave the furniture entirely.

---

## Measurement basis

All measured figures come from **"Lalou - Paloma Corner Sofa [v1.5]"**,
QuickySitter 1.26, 2026-07-27: 4 sitters, 21 props, 8 animesh bodies, sitB menus
of 230 to 276 items, `Storage=73183`, `LSD room=914 poses`.

**Do not compare figures across different furniture.** Before and after
comparisons must use the same object in the same configuration.

| Script | Free after boot |
|---|---|
| `[QS]sitB` (4 instances) | 14216 / 14352 / 14354 / 14376 |
| `[QS]boot` | 8220 |
| `[QS]sitA` (4 instances) | 5712 / 5750 / 6072 / 6130 |

Rules of thumb from the same measurement round: ~50 bytes per line of real code;
15 to 17 bytes for an additional LSD call using an existing string literal;
comments are free.
