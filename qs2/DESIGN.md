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
[QS]boot  +  [QS]core  +  [QS]seat  +  [QS]menu  +  N x [QS]anim
```

| Script | Instances | Owns |
|---|---|---|
| `boot` | 1 | Notecard to LSD, as today |
| `core` | 1 | **What is played.** Item model, pose resolution, offsets, security gating, camera, plugin and HUD wire |
| `seat` | 1 | **Who sits where.** Prim binding, sit targets, occupancy table, lifecycle, swap, the animator fleet |
| `menu` | 1 | Dialog rendering and dispatch, plugin registry, HUD menu wire |
| `anim` | N | Holds `PERMISSION_TRIGGER_ANIMATION` for its occupant. Starts and stops animations on request. Nothing else. |

The `core` / `seat` split costs nothing on the hot path. Occupancy lives in LSD
(`qs:occ:*`), written by `seat`, so `core` reads it directly instead of asking.
At pose start `core` resolves everything (which seats take part, which
animation, which offset) and sends `seat` **one** message. That is exactly as
much wire as today's sitB to sitA hop, so it is not a regression.

**Naming.** Earlier drafts called the singleton `[QS]station`, which stopped
matching once the notecard unit became `ITEM`. `[QS]control` was considered and
rejected: "control" is already taken in this codebase and means something else,
namely *who operates the menu*. `[QS]root-control` is the AVcontrol fork that
lets a third party drive someone's menu, `CONTROLLER` is the operating avatar
throughout sitA and sitB, and the HUD repo has `hudcontrol`. A second meaning
would make "check the control script" ambiguous in support.

`[QS]core` says "the main one" without claiming a word that is spoken for, and
the names read as a set: `boot`, `core`, `seat`, `menu`, `anim`.

`seat` is a singleton despite the singular name; it manages all seats. The
per-seat script is `anim`.

### Principle: no authoring code in the base scripts

**Stated as a requirement by the product owner, 2026-07-28.** Nothing a creator
needs while building may live in a base script, including the code that builds
its menu entries. `/5 cleanup` must be able to remove everything that normal
operation does not need.

> `menu` knows how to render a registry. It does not know what an adjuster is.

Today the gate is presence based but the bytes are permanent. `sitB` names
`[HELPER]`, `[HELPER HUD]`, `[QUICKYHUD]`, `[NEW]`, `[SAVE]`, `[DUMP]` and
`[ADJUST]` literally, and threads `OLD_HELPER_METHOD` through five handlers
([sitB.lsl:671], [sitB.lsl:697], [sitB.lsl:903], [sitB.lsl:1455]). Removing the
adjuster hides the entries; it does not reclaim anything.

**The mechanism already exists, three times over.** `QSPLUG_REGISTER` lands in
`[OPTIONS]`, `QSADJ_REGISTER` lands in `[ADJUST]`, and hudadmin's `menuplus`
mode registers its own entry. Three ways to do one thing, each with a fixed
destination.

v2 has **one** registration wire with a **placement** field, and the placement
is a menu path of the kind the notecard format already uses:

```
register "[HELPER]"      -> top level
register "Mein Werkzeug" -> "Extras/Werkzeuge"
```

**Specified in [REGISTRY.md](REGISTRY.md)**, including the backward compatible
payload that keeps existing plugins running unchanged.

`[QS]adjuster` registers its own entries, `[QS]offset` registers the personal
adjust entry, the HUD registers its own. No base script carries a literal for
any of them.

Three consequences:

1. **`/5 cleanup` becomes real removal.** The entries do not exist because
   nobody registered them, rather than existing and being hidden. Removing the
   script removes its bytes with it.
2. **`menu` gets smaller**, by an estimated 80 to 110 lines of literals, tail
   building and `OLD_HELPER_METHOD` plumbing, plus 40 to 60 from collapsing
   three registries into one. That puts it near **760 lines, about 38 KB**, and
   settles the concern in 6.4 about `menu` being the tight one.
3. **Third-party creator tools become first class.** `[QS]objectadjust` has been
   public since 1.25 and would use the same path as the in-house adjuster
   instead of a second-class one.

Two costs, stated plainly:

* **A race class.** A registry-driven menu is complete only once the
  registrations have arrived. That is already true for `[OPTIONS]` and the
  re-announce pattern exists, but a missing **top level** entry is far more
  visible than a missing one inside a submenu.
* **Ordering.** Notecard entries and registered entries in the same menu need a
  deterministic order. Proposal: notecard entries first, registered ones after
  in registration order, with no sort keys offered.

The principle is broader than the adjuster. `/5 targets` (90298) sits in `sitA`
today and is a pure debugging tool; it belongs in `[QS]debug`.

### Why not fewer scripts

`core` and `menu` cannot be one script. That fails on exactly the arithmetic
that kills the "merge sitA and sitB per seat" idea: 59824 + 51320 = 111144
against a 65536 limit, **45608 bytes over** (**measured** inputs). The split is
forced by the byte ceiling, not chosen for tidiness.

The goal is therefore not "as few scripts as possible" but **as few instances of
the same bytecode as possible**.

### Why the per-seat script cannot be removed entirely

See section 3.

### Projected sim memory

**A correction to how this was first framed.** A Mono script is *allocated* 64 KB
regardless of how much it uses; that allocation is what sim script memory
accounting counts, and lowering it is exactly what `llSetMemoryLimit` is for.
Earlier versions of this section compared *used* bytes, which flatters the
result. Counting allocations instead:

Scripts that change, per piece of furniture (`boot` and the plugins are in both
columns and are omitted):

| Four seater | Scripts | Allocated |
|---|---|---|
| today | 4 x sitA + 4 x sitB | 8 x 64 = **512 KB** |
| v2, no memory limits | core, seat, menu, 4 x anim | 7 x 64 = **448 KB** |
| v2, with memory limits | 32 + 32 + 52 + 4 x 8 | **148 KB** |

| Eight seater | Scripts | Allocated |
|---|---|---|
| today | 8 x sitA + 8 x sitB | 16 x 64 = **1024 KB** |
| v2, no memory limits | core, seat, menu, 8 x anim | 11 x 64 = **704 KB** |
| v2, with memory limits | 32 + 32 + 52 + 8 x 8 | **180 KB** |

Two things follow, and the second one is easy to miss:

1. **`llSetMemoryLimit` is not a refinement, it is the mechanism.** Without it
   the rebuild buys 13 % at four seats. With it, factor 3.5 at four seats and
   factor 5.7 at eight. See section 8, question 2.
2. **Splitting `core` into `core` and `seat` costs 64 KB if limits are not
   set**, and nothing if they are. The split is therefore conditional on the
   same prerequisite as everything else here.

The per-script limits above are estimates with headroom over the line counts in
section 6.4, not measurements. `anim` at 8 KB is the least certain of them.

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
written. On the real "BED ENGINE 2026" notecard it is 372 of 816 lines, so
structure de-duplication alone saves 28 % while removing the offsets would save
74 %. The earlier factor-of-six figure came from a synthetic stress file with
six offset lines and measured only the structure half.

#### Offsets stay in the notecard

**Decided 2026-07-28.** Living in LSD alone was considered for the size win and
rejected. The notecard stays the source of truth and LSD stays a derived cache.
The reasoning is durability, and it is written down here so the idea is not
re-proposed on the size argument alone:

* **A notecard change wipes them.** [boot.lsl:1545] deletes
  `^qs:(meta|cfg|sitter|p|nm|nt|boot):` whenever the notecard asset key changes,
  and `qs:p` is where offsets live. With LSD as the only home, adding one pose
  would destroy every adjusted position in the furniture.
* **Making that wipe selective reintroduces what it exists to prevent.** It is
  blunt precisely so that renamed or deleted poses cannot leave orphaned offsets
  behind.
* **A sibling reset would become unrecoverable.** `llLinksetDataReset()` called
  by a non-QS script in the same object is a documented incident class. Today it
  is repaired by re-seeding from the notecard. With LSD as primary store it
  would be total loss of the creator's adjustment work.
* **Text backup, versioning and hand-off disappear**, unless every creator runs
  `[DUMP]` with discipline.
* **Unverified either way:** whether LSD survives take-to-inventory and re-rez
  unchanged. For a primary store that would need proof rather than assumption.

**The size win is therefore 28 %, not 74 %.** The editor limit can still be
addressed without touching durability, by splitting structure and offsets across
**two notecards**: the hand-edited one holds 214 lines and the machine-written
one is never opened. The limit is per notecard, not per object, and both remain
assets that re-seed LSD exactly as today. That option is open; whether it is
worth `boot` reading a second card is not decided.

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
* **Format first, with an offline converter.** `boot` learns only the new
  dialect; legacy files are converted ahead of time. Costs boot nothing, but
  existing customers must run their notecard through a tool once. That is a
  support question, not a technical one.
* **Format first, with a dual parser in boot.** Seamless for customers, but
  someone has to show the 8220 bytes are enough first.

**Decided 2026-07-28: the converter, no dual parser.** Legacy support leaves the
furniture entirely and moves into a tool, where bytes are free.

Three things follow.

**A dialect detector is still required.** Not a parser, ten lines: if `boot`
sees a `SITTER` token it is looking at a v1 notecard, and it must say so with
the converter's address rather than quietly building empty furniture. Somebody
will drop v2 scripts into existing furniture on day one. Cheap insurance
against the worst support case, and it is what makes "no dual parser" safe
rather than merely cheaper.

**Client side rather than server side.** Unlike `[DUMP]`, conversion is a pure
text transform with no server requirement. Running it in the browser means a
creator's pose list never leaves their machine, there is no service to operate,
and it keeps working if the site is down. With content of this kind that is a
trust argument, not a technical one.

**The converter inherits the reporting duty.** It resolves the divergence
classes in question 4b, per-sitter menu flags and differing pose order, but it
has to state what it chose. Same for the internal pose IDs it assigns on label
collision (5.2).

**Scope note against 7.5.** Stock AVsitter compatibility is kept for the
**wire**, so stock plugins keep working. It is deliberately *not* kept for the
**notecard dialect**, because reading both would cost `boot` bytes it does not
have. This is the "decided on its own merits" clause of 7.5 being exercised
once, not a reversal of it.

### Revised order

1. The converter ships, and `settings.php` learns the new `[DUMP]` layout.
2. `boot`, the engine and the dialect detector ship.

The converter has to exist first, because with no dual parser it is the only
migration path there is.

**The server side moves first, whichever option wins.** `[DUMP]` has to emit the
new format, and the grouping is done in `settings.php` rather than in `boot`, so
a format change is also a PHP change. The existing rule already says the PHP
deploys ahead of the boot that depends on it. Getting this backwards means
creators press `[DUMP]` and receive a notecard the new `boot` cannot read.

---

## 6. Block inventory of the current scripts

Line counts are function boundaries; `link_message` blocks are attributed by
handled message number and are therefore rougher. The last column is the one
that matters.

### 6.1 `[QS]sitA`, 1629 lines

| Block | Where | ~Lines | Per seat? | Target |
|---|---|---|---|---|
| Boot and config | globals, `qs_load_from_lsd()` 140-284, 90024/90023 | 250 | no | `core` and `seat`, each reads its own keys |
| Sit targets | `sittargets()` 324-399, `set_sittarget()` 430-463, `primcount_error()`, `IsInteger()`, desc parsing | 130 | no | `seat`, shrinks |
| Occupancy and lifecycle | `changed()` 1252-1557, `release_sitter()`, `end_sitter()`, `run_time_permissions()` 1558-1629, 90060/90065/90070 | 430 | **partly** | `seat` + `anim` |
| Play animation | `apply_current_anim()` 528-593, `update_current_anim_name()`, `sit_using_prim_params()`, `is_sync_pose()`, `do_resync_tick()`, `timer()` | 190 | **only the start/stop calls** | `core` resolves, `seat` dispatches, `anim` plays |
| Personal offsets | `lookup_personal_offset()`, `dialog()`, `adjust_pose_menu()`, `listen()` 776-888, 90260/90265/90263 | 300 | no | UI to `offset`, lookup to `core` (6.5) |
| Swap | 90030/90031 | 80 | no | `seat`, becomes a table swap |
| Inter instance protocol | 90045 broadcast, 90150, 90070, 90055/56/57, `SITTERS` replication, `one == SCRIPT_CHANNEL` checks | 180 | no | **disappears** |
| Legacy and debug | 90075/90076 (`OLD_HELPER_METHOD`), `OLD_SYNC`, `HASKEYFRAME`, 90298, 90011/90033/90001/90002 | 90 | no | product decision |
| Camera | 90202, `llSetLinkCamera` | 15 | no | `core` |

The two giants are `changed()` at 306 lines and `link_message()` at 363,
together 41% of the file.

### 6.2 `[QS]sitB`, 1643 lines

| Block | Where | ~Lines | Per seat? | Target |
|---|---|---|---|---|
| Menu rendering | `animation_menu()` 246-468, `reorder_dialog_buttons()`, `qs_pose_data()`, `page_map`/`nav_stack` | 260 | no, but needs **per operator state** | `menu` |
| Dialog dispatch | `listen()` 768-1076 | 309 | no, same | `menu` |
| Adjust UI | `adjust_dialog()` 644-738, `adjust_allowed()`, `in_adjust_menu` branch, QSADJ_REGISTER/UNREGISTER, `ADJUST_DYN`/`ADJUST_MENU` | 270 | no | `offset` plugin (6.5) |
| Plugin registry | `plugin_dialog()` 573-625, QSPLUG_REGISTER, 90201/90202/90203 | 120 | no | `menu` |
| Pose dispatch | 90000/90050/90005, POSE vs SYNC decision, `send_anim_info()`, 90045 receive, 90055 | 150 | no | `core`, shrinks |
| Boot and config | `qs_load_from_lsd()` 507-572, QS_BOOT_WIPE/RELOAD, QSALIVE, `memory()` | 120 | no | **merges with 6.1 row 1** |
| Menu sidecar index | `qs_rebuild_sidecar()` 469-506, writes `qs:nm`/`qs:nt` | 38 | no | `boot`, built once per item |
| Security and access | `changed()` 1077-1141, `llUnSit`, `has_security`, `select_present()`, `rlv_present()` | 90 | no | `core` |
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

### 6.4 Where it lands: target script contents

Line counts in this section are **estimates** derived from the inventory above,
not measurements. Nothing has been written.

Both `core` and `seat` are defined as much by what they do not contain:

| Gone | To |
|---|---|
| `listen()` and every `llDialog` | `menu` |
| `run_time_permissions()` and every `llStartAnimation` / `llStopAnimation` | `anim` |
| The inter instance protocol | nothing, it disappears |

Neither holds a listener, which removes channel allocation, listener teardown
and the whole orphaned-listener failure class from the seat engine.

**Shared state lives in LSD, not in messages.** `seat` writes it, everyone else
reads it:

```
qs:occ:<item>/<seat> = <avkey>     occupancy
qs:cur:<item>/<seat> = <poseId>    what is currently playing
```

This replaces the `SITTERS` list replicated into every instance today and the
messages that keep those copies in sync. It is also why the `core` / `seat`
split does not cost a round trip: `core` reads occupancy, it does not ask for
it.

#### `[QS]seat`, who sits where

**Data.** The seat and item tables in RAM:

```
SEATS = [item, name, primLink, occupant, poseId, animHandle, ...]
ITEMS = [name, firstSeat, seatCount, ...]
```

**Functions.** `resolve_bindings()` (prim names to items, seats to prims, `PRIM`
overrides), `place_sittargets()`, `seat_of_link()` / `seat_of_avatar()`,
`release_seat()` / `end_seat()`, `swap_seats()`, and the animator fleet:
assignment, census, handing out permission orders.

**Events.** `state_entry`, `changed(CHANGED_LINK)` as the occupancy engine,
`changed(REGION_START / OWNER)`, `touch_start` (resolve the touched prim to an
item, then ask `menu` to open it), `link_message`.

| Block | ~Lines |
|---|---|
| Config it reads for itself | 80 |
| Binding and sit targets | 80 |
| Occupancy and lifecycle | 250 |
| Swap | 30 |
| Animator fleet | 40 |
| **Total** | **~480, roughly 24 KB** |

#### `[QS]core`, what gets played

**Functions.** `start_pose()` (resolve which seats take part, which animation
each gets, which offset applies, then one message to `seat`), `apply_offsets()`
(plain LSD reads, default from `qs:p` and personal from `QSO`), the security and
access gating, camera, and the plugin and HUD wire.

**Events.** `state_entry`, `changed(CHANGED_INVENTORY)` for reload,
`link_message`, `timer` for sequences and the resync tick. No `listen`, no
`changed(CHANGED_LINK)`, no `run_time_permissions`.

| Block | ~Lines |
|---|---|
| Config it reads for itself | 120 |
| Play pose | 130 |
| Offset lookup and apply | 40 |
| Pose dispatch, from sitB | 80 |
| Security and access | 90 |
| Camera | 15 |
| **Total** | **~475, roughly 24 KB** |

Note the config load is **not** duplicated the way sitA and sitB duplicate it
today. Each script reads the LSD keys it actually needs; there is no shared
loader to copy.

#### `[QS]anim`

Reactive only. Announces itself on `state_entry` (section 7.3), then acts on
instructions: take permission for this avatar, start this animation, stop. It
reports back when permission has landed. It needs no `changed()` of its own,
because `seat` drives it. Estimated 120 to 150 lines.

#### Division of labour when someone sits

1. `changed(CHANGED_LINK)`: `seat` sees avatar K on seat `Bett/Links`, writes
   `qs:occ:Bett/Links`.
2. `seat` assigns a free animator and tells it to acquire permission for K.
3. Animator: `llRequestPermissions`, `run_time_permissions`, reports ready.
4. `core` picks the start pose, resolves animation and offset per participating
   seat, and sends `seat` one message with the resolved payload.
5. `seat` sets the sit targets and sends one `LINK_SET` message: all
   participating animators start their animation.

Step 5 is why `SYNC` is unaffected. Every animator already holds its permission,
so they all fire in the same frame, exactly as the per-seat scripts do today.

Step 2 assumes nothing new. The current `sitA` instances all live in **one**
prim and animate avatars sitting on other prims, because permission binds to the
linkset rather than to the prim. That is demonstrated by the shipping product,
not an assumption to verify.

#### `[QS]menu` and where its relief comes from

Taken whole, `menu` would be the tightest of the singletons: rendering (260)
plus dispatch (309) plus adjust UI (270) plus plugin registry (120) plus HUD
wire (120), plus new per operator state, is roughly **1180 lines, about 59 KB**.

Two moves fix it, and both are required by decisions taken elsewhere rather
than chosen for size:

1. The personal-offset adjust UI belongs with the data that `[QS]offset` already
   owns, and **`[QS]offset` has 38960 bytes free** (measured). Minus 270 lines.
2. The authoring literals and the three-way registry collapse, per the principle
   in section 2. Minus a further 120 to 170.

That leaves `menu` at roughly **760 lines, about 38 KB**, which is the most
headroom of any of the singletons.

Only the **editing UI** moves. Lookup and application stay in `core` as direct
LSD reads. Routing them through the plugin would add a wire round trip to every
pose start, and the pose would visibly jump into place.

**If `menu` turns out tight anyway**, the order of further relief is:

1. Plugin registry list to LSD (`qs:plug:*`), read on demand, same pattern the
   poses already use. Saves the resident list, little code.
2. The re-sync and anim-info wire (90271, `send_anim_info`) to `core`, where the
   pose state already lives. It is in `menu` today only because `sitB` happened
   to own it.
3. Splitting the dialog code itself, and then the cut is **by dialog family**
   (pose menu against options and admin), not by relocating pieces into `seat`.

Moving dialog work into `seat` is the one thing that does not help. Rendering
and dispatch need a `listen` and `llDialog`, and giving those to `seat` rebuilds
exactly the entanglement that was just removed from the seat engine.

### 6.5 The authoring path

Two different things are called "the adjuster menu" and they are affected
differently. Both survive.

#### The creator tool, `[QS]adjuster`

Unchanged in concept, but it takes over work that `sitB` does for it today. Per
the principle in section 2 it now **registers its own menu entries** (`[HELPER]`,
`[HELPER HUD]`, `[QUICKYHUD]`, `[NEW]`, `[SAVE]`, `[DUMP]`) instead of `menu`
knowing they exist. The presence flag `qs:alive:adjuster` stays as the gate for
things other scripts must decide, but it no longer gates hidden code.

That makes `/5 cleanup` do what its name says: the entries disappear because
their owner is gone, not because a flag was retracted.

Three things it has to learn:

**Addressing.** It writes to `qs:p:<ch>:<i>` today with `<ch>` as the slot index
([adjuster.lsl:146]). The address becomes `<item>/<seat>`. Mechanical, but it
touches every read and write site.

**`[DUMP]` emits the new format**, and that has a consequence outside the
furniture: the grouping is done server side in `settings.php`, not in `boot`. A
format change is therefore **also a PHP change**, and by the existing rule the
PHP has to be deployed before the boot that depends on it. This belongs in the
rollout order, not in the follow-up work. See 5.4.

One small thing gets better: "which slot am I adjusting" becomes "which seat",
and seats have readable names.

#### The end-user personal-offset menu

`adjust_dialog()`, `adjust_allowed()`, the `in_adjust_menu` branch and
`ADJUST_DYN` in `sitB`, plus `adjust_pose_menu()` with the X+/Y+/Z+ buttons in
`sitA`. Unchanged as a feature, but it changes address:

| Part | Today | v2 |
|---|---|---|
| Dialog and buttons | sitB + sitA | `[QS]offset` |
| Lookup and apply | sitA | `core`, direct LSD read |
| Saving | 90260/90262 to sitA | `[QS]offset` writes it itself |

This is the same move that takes `menu` from 59 KB to 46 KB, and it is not
arbitrary: `[QS]offset` already owns the data, it has simply never edited it.

#### Plugin authors are unaffected

`QSADJ_REGISTER` (90213) and `QSADJ_UNREGISTER` (90216) are broadcast with
`LINK_SET`. Relocating the receiver from `sitB` to `[QS]offset` is invisible to
the sender, so `[QS]objectadjust` and third-party adjust plugins keep working as
long as the numbers stay.

#### What disappears

`sitB` runs **two paging state machines side by side** today, `adjust_page`
next to `menu_page`, with the attendant question of whether a `[<<]` is paging
the pose menu or the adjust menu. Once the two live in different scripts, that
question cannot be asked. That is worth more than the lines it saves.

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

### 7.3 How `seat` learns about its animators

Per the project convention: **they announce, they are not probed.** Either a
`qs:alive:anim:*` flag or a census reply, the same pattern the plugins already
use. Never `llGetInventoryType("[QS]anim 3")`.

### 7.4 Consequence: animators need no name suffix

Permission is bound to the avatar, not to the prim, so `llStartAnimation` does
not care which animator serves which seat. The only real constraint is that the
animations must live in the same prim as the animator script, and the QS scripts
all sit in one prim anyway.

The N animators are therefore **interchangeable and anonymous**. `seat`
assigns seats at runtime and addresses each animator by the handle it reports
itself (`llGetScriptName()`), not by an index someone derives from a name. The
creator drops N identical copies and is done.

This removes the last name-derived identity in the system, `SCRIPT_CHANNEL`
parsed out of the script name ([sitA.lsl:706], [sitB.lsl:747]). That is exactly
what the convention has been arguing against since the RLV rename broke the old
`[AV]root-RLV` name probe.

### 7.5 Stock AVsitter compatibility

**Decided 2026-07-28.** Keep it where it can be kept. If it ever stands in the
way of a gamechanger feature, that specific conflict gets decided on its own
merits rather than by the general rule.

It turns out the rule costs very little, because the conflict everyone expects
does not materialise.

**Wire addressing stays integer.** The 900xx messages keep slot indices.
`<item>/<seat>` is the naming and storage layer above it, and `seat` holds the
mapping, which it has anyway in its seat table. Nothing a stock plugin sends or
receives changes, including on multi-item furniture, because the seats of all
items still enumerate into one index space on the wire.

Separating the two layers is what keeps the compatibility promise and the
multi-item capability from colliding. Storage isolation between items
(`qs:<item>:...`) is unaffected: it is a different layer.

**What stays because of this decision**, and is therefore still counted in the
line estimates:

* `OLD_HELPER_METHOD` and the 90075 / 90076 helper path
* the `select_present()` and `rlv_present()` name-probe fallbacks (7.1)
* the legacy block in 6.1

**Verified, not assumed:** the only script-name probe for `sitA` anywhere in
stock is in `[AV]object` ([avstock/Plugins/AVprop/[AV]object.lsl:83]), and it
inspects the **prop's own inventory** rather than the furniture's. The singleton
split does not touch it. That was the most dangerous candidate, since
`[AV]object` is experience-compiled and must not be forked.

**The one residual limitation.** A stock plugin in a multi-item linkset is
**item-blind**: it sees seat 5, not "the chair's seat". For plugins reacting to
"pose X started on slot 5" this is invisible. Anything needing item context is a
v2-aware plugin by definition. This is a documented limitation, not a break, and
it only arises on furniture shapes that cannot exist today.

---

## 8. Open questions and measurements needed

| # | Question | Blocks what |
|---|---|---|
| 1 | Real size of `[QS]anim`. Estimated at 8 KB from 120 to 150 lines (section 6.4); unverified. | The whole memory projection in section 2 |
| 1b | Whether `menu` fits. Estimated ~760 lines / 38 KB after the adjust UI moves to `[QS]offset` and the authoring literals leave, with a documented relief order if not. | Sections 2 and 6.4 |
| 1c | Placement vocabulary and ordering for the unified registration wire, and how visible the top-level registration race is in practice. See [REGISTRY.md](REGISTRY.md) section 8. | The section 2 principle |
| 2 | `llSetMemoryLimit` appears in **no** script in the repo. Without it every instance books the full 64 KB and the projection is void. Needs a peak measurement per script plus headroom, otherwise stack-heap collisions. | Section 2, and it is a win available today without any rebuild |
| 3 | Per operator dialog state in a singleton `menu`. Design, not measurement. | Section 6.3 |
| 4 | Collision rate in the existing stock: how often do identically named `POSE` entries occur across sitter blocks. **First real data point 2026-07-28: zero** in "BED ENGINE 2026", where seat 1 has no `POSE` lines at all and every coupled pose is correctly authored as `SYNC`. One well-built file is not a rate; more of the stock still needs counting. | Section 5, and therefore the sequencing choice in 5.4 |
| 4b | Divergence classes found in the same file that the converter must report: a menu carrying different flags per sitter (`MENU PRONE\|V` against `MENU PRONE`), and identical pose sets in different order within a menu. | Section 5.1 assumption 5 |
| 5 | LSD budget after de-duplication. Re-measure `Storage=` on the reference sofa with a converted notecard. | The "several pieces of furniture in one linkset" goal |
| 6 | ~~Does v2 keep stock AVsitter compatibility.~~ **Decided 2026-07-28: yes, see 7.5.** Kept where it can be kept, with any specific conflict against a gamechanger feature decided on its own merits. | Resolved. The legacy blocks stay and remain counted in the estimates. |

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
