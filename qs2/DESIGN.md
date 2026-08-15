# QuickySitter v2 engine, design draft

**Status: the format half is CANCELLED, 2026-07-29.** The runtime half stands.

The notecard format change described in section 4 and in
[FORMAT.md](FORMAT.md) will not be built. It rested on a size argument that
turned out to be false (section 1.1), and once that fell away the remaining
case was comprehensibility alone. Multiple items in one linkset — the other
goal it was carrying — needs a single `ITEM` grouping token, not a new format.

**What replaces it:** an online editing tool for the *existing* AVpos format.
The pain the format change was aimed at is real; it is just editing pain rather
than format pain, and a tool addresses it without a migration, a converter, or a
break in compatibility.

**What still stands:** section 1.2 and the runtime split. 512 KB against 148 KB
on a four seater is measured, and it is independent of the notecard format
(section 1.4).

Sections 4, 5 and [FORMAT.md](FORMAT.md) are kept as a record of the reasoning,
not as a plan. [REGISTRY.md](REGISTRY.md) survives: it is a runtime mechanism and
does not depend on the format.

**Direction, revised: build it in LSL now, port to SLua later.**

An earlier decision the same day made v2 *be* the SLua rewrite. Reversed,
because SLua only runs in beta regions and therefore ships to nobody. Writing it
twice is the price, and it is a low one: the second writing is a port of working
code rather than a design under time pressure, and section 9 establishes that
SLua and LSL coexist in a linkset, so the port can go one script at a time.

**What v2 therefore is: a drop-in replacement for `sitA` and `sitB`.** This
follows from the two decisions together. With the format change cancelled,
`core` / `seat` / `menu` read the **v1 LSD schema** that today's `boot` already
writes. With stock compatibility kept (section 7.5), they speak the existing
900xx wire. So:

| | changes |
|---|---|
| the notecard | no |
| plugins | no |
| the HUD | no |
| `boot`, `prop`, `faces`, `offset`, RLV | no |
| `sitA` + `sitB`, 2N scripts | **become 3 singletons** |

A four seater goes from nine scripts to four. The creator swaps scripts and
nothing else.

That is also a better pitch to creators than "fewer scripts" sounded like
earlier in this document. Script count and memory are visible in the object's
contents and in a region's top-scripts list, and sim operators evict on exactly
that. "A quarter of the script memory" is an argument that reaches the customer.

Everything marked **measured** comes from the reference furniture (see
Measurement basis). Everything else is derived from the code or from LSL
semantics and is flagged as such.

In-world so far: the permission-cycling measurements in section 3, and stage 1
compiling on 2026-07-29. Nothing else has been reproduced.

Related prior record: the Google Doc "QuickySitter: SET, Stations, and a
From-Zero Seat Model" (2026-07-27) covers sections 4 and 5 in an earlier form.

---

## 1. The problem

### 1.1 The notecard is not meaningfully redundant

**This section previously claimed the opposite. Corrected 2026-07-29 after
measuring two real notecards; the correction is kept visible because it was the
founding premise of this whole document.**

The original claim was that a classic AVpos repeats the menu skeleton once per
`SITTER` block, and that this dominates both notecard size and LSD storage. It
was derived from a synthetic stress file where the menus were 312 of 3432
structure lines, and from line counts rather than bytes.

Measured on the real "Lalou" notecard, 1013 lines and 26948 bytes:

| | lines | bytes | share |
|---|---|---|---|
| offsets | 394 | 15328 | 57 % |
| `SYNC` | 334 | 6863 | 25 % |
| `POSE` | 60 | 1101 | 4 % |
| `TOMENU` | 46 | 662 | 2.5 % |
| `MENU` | 48 | 594 | 2.2 % |

What v2 saves: `TOMENU` disappears (−662 B), `MENU` halves (−297 B), `SYNC`
pairs merge (−835 B), `POSE` gains seat names (+300 B), `OFFSETS` markers
(+50 B). **Net about −1450 B of 26948, so 5 %.**

**Why the premise was wrong.** Merging two `SYNC` lines saves exactly one
repetition of the *label* and pays for the seat names:

```
SYNC Nice|S37F                      15 B
SYNC Nice|S37M                      15 B
POSE Nice|Girl=S37F|Guy=S37M        29 B
```

One byte. The saving per merged pair is `len(label) − 3`, and labels are short.
The deeper reason: the two `SITTER` blocks are **not copies of each other**.
`S37F` and `S37M` are different animations, which is the entire purpose of
having two blocks. Only the navigation scaffolding is duplicated, and that is
under 5 % of the file.

The same correction applies to the storage figure. `Storage=73183` on the
reference sofa is real, but it is dominated by pose data that genuinely differs
per sitter, not by copies of a menu tree.

**Consequences, stated plainly:**

* v2 does **not** solve the notecard editor limit. It is roughly size-neutral
  (see [FORMAT.md](FORMAT.md) §5).
* v2 does not free up meaningful LSD either, so "several pieces of furniture in
  one linkset" has to stand on the item model itself rather than on reclaimed
  storage.

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

### 1.3 What v2 is therefore for

With 1.1 gone, the case rests on three things rather than four:

1. **Script memory**, 1.2. The only measured, large redundancy there is.
2. **Comprehensibility.** Four tokens instead of seven concepts, coupling that
   is written down instead of arising from two blocks happening to use the same
   name, no `MENU`/`TOMENU` trap, and typos that surface as parse errors with a
   line number instead of silent no-ops.
3. **Several pieces of furniture in one linkset**, which the item model makes
   possible and which no amount of tidying the v1 format would.

**Notecard size is not on the list.** Neither is the editor limit.

### 1.4 The two changes are independent

Neither requires the other. The singleton split works with today's integer slot
addressing; the new notecard format works on today's 2N+1 runtime. They can
ship separately and be rolled back separately.

That independence matters more now than it did: the runtime half carries the one
measured benefit, and the format half carries the other two. If only one of them
is ever built, this is the seam to cut along.

---

## 2. Target runtime architecture

```
[QS]boot  +  [QS]core  +  [QS]seat  +  [QS]menu
```

**Four scripts, whatever the seat count.** `N x [QS]anim` was here until
2026-07-29, when an in-world test showed that permission cycling works
synchronously (section 3). `seat` acquires each occupant's permission and
starts its animation in the same handler, so nothing is left that has to exist
once per seat.

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

**Updated 2026-07-29**, after `[QS]anim` was removed (section 3). The v2 rows no
longer depend on seat count at all.

| Four seater | Scripts | Allocated |
|---|---|---|
| today | 4 x sitA + 4 x sitB | 8 x 64 = **512 KB** |
| v2, no memory limits | core, seat, menu | 3 x 64 = **192 KB** |
| v2, with memory limits | 32 + 32 + 52 | **116 KB** |

| Eight seater | Scripts | Allocated |
|---|---|---|
| today | 8 x sitA + 8 x sitB | 16 x 64 = **1024 KB** |
| v2, no memory limits | core, seat, menu | 3 x 64 = **192 KB** |
| v2, with memory limits | 32 + 32 + 52 | **116 KB** |

Factor 4.4 at four seats and **8.8 at eight**, and unlike every earlier version
of this table the v2 side is flat: an eight seater costs exactly what a two
seater costs. That also means the benefit no longer depends on
`llSetMemoryLimit` to be worth having — 192 KB against 1024 KB stands without
it, where the earlier N-animator arithmetic did not.

Two things follow, and the second one is easy to miss:

1. **`llSetMemoryLimit` is not a refinement, it is the mechanism.** Without it
   the rebuild buys 13 % at four seats. With it, factor 3.5 at four seats and
   factor 5.7 at eight. See section 8, question 2.
2. **Splitting `core` into `core` and `seat` costs 64 KB if limits are not
   set**, and nothing if they are. The split is therefore conditional on the
   same prerequisite as everything else here.

The per-script limits above are estimates with headroom over the line counts in
section 6.4, not measurements. `anim` at 8 KB is the least certain of them.

**How wrong the `anim` estimate can be without changing anything**, since it is
the one figure multiplied by seat count:

| `anim` actually is | Four seater | against today's 512 KB |
|---|---|---|
| 8 KB (estimate) | 148 KB | factor 3.5 |
| 16 KB | 180 KB | factor 2.8 |
| 24 KB, triple the estimate | 212 KB | factor 2.4 |

The conclusion survives a threefold error. Open question 1 therefore sharpens
this projection rather than gating it, and an earlier phrasing calling it a
blocker on "the whole memory projection" overstated the case. What genuinely
gates it is question 2: without `llSetMemoryLimit` none of these rows apply at
all.

---

## 3. Permission cycling: rejected, then MEASURED AND WRONG

**Overturned in-world 2026-07-29.** The rejection below was wrong. It is kept
because the reasoning is instructive about how it went wrong, but the conclusion
does not hold.

`qs2/test/permtest.lsl`, two seated avatars, two requests and two
`llStartAnimation` calls in **one** event handler:

```
START a  av=c648fc06  granted=1  keyMatches=1  anims 7 -> 8
START b  av=08a811cd  granted=1  keyMatches=1  anims 5 -> 6
run_time_permissions fired, perm=16 for 08a811cd
run_time_permissions fired, perm=16 for 08a811cd
```

Both avatars animate. **The grant is synchronous for an avatar already seated
on the object**: `llRequestPermissions` returns with the permission in effect,
and the following `llStartAnimation` reaches that avatar. `run_time_permissions`
arrives *after* the work is done, so it is a notification, not a gate. Note it
fires twice and reports the *last* key both times, so it cannot even be used to
tell the two requests apart; in this pattern it must be ignored.

Avatar `a` keeps its animation while `b` is requested, confirming that losing
the permission does not stop what is already running.

**Consequences.** There is no per-seat script. `[QS]anim` is unnecessary and the
engine is `boot` + `core` + `seat` + `menu`, a **fixed** script count
independent of seat count. The memory case gets stronger and stops degrading
with seat count (section 2).

**The pose change and the stop path also pass**, run 2026-07-29. Phase 2 uses
the two-pass pattern the engine would need (acquire and start every seat, one
shared `llSleep(0.2)`, then acquire and stop every seat), and both avatars end
phase 3 back at their phase-1 starting counts: `a` 7 → 7, `b` 5 → 5. Nothing is
left running, so the second pass really did stop the old animations.

**And the visual check passes for two seats:** the matched sway pair runs in
phase. That was the actual question, since a frame of offset in a looping couple
pose is permanent.

**Clean run with the avatars' AO switched off**, and every reading matches the
model exactly:

| Phase | a | b | expected |
|---|---|---|---|
| START | 6 → 7 | 5 → 6 | +1 |
| SWAP | 7 → 7 | 6 → 6 | unchanged |
| STOP | 7 → 6 | 6 → 5 | −1 |
| round trip | 6 → 6 | 5 → 5 | level |

Two things about measuring this, both learned the hard way:

* **An AO makes `llGetAnimationList` useless.** Two identical runs with the AO
  on gave 7→8 and then 8→8 for the same call. The test was built on the
  assumption that counting is definitive and eyeballing unreliable; it is the
  other way round. Switch the AO off, or check the animation's asset UUID via
  `llGetInventoryKey` where it is full-perm.
* `run_time_permissions` fires once per request, always late, and always reports
  the *last* key. In phase 2 that is four events, all naming the same avatar. It
  carries no usable information here and the engine must ignore it outright.

**It scales.** Measured over 200 acquire+start pairs in one handler, so the
total sits far above the frame resolution:

```
COLD STRESS: 200 acquire+start in 245 ms  =  1.2 ms each
             ->  8 seats would take 10 ms   (frame ~22 ms)
```

**1.2 ms per seat.** An eight seater starts every animation inside one frame,
with a factor of two in hand. Sixteen seats would still fit, barely. So there is
no seat count at which the handler has to be split, and `SYNC` is exact rather
than merely close.

**Do not measure this with `llGetTime` at small N.** It resolves in whole
frames: every reading at 2 to 8 pairs came out as 22, 45 or 66 ms, and eight
pairs once read *less* than two pairs had in the run before. A cold-versus-warm
difference was read out of those numbers and was pure quantisation noise. Three
instruments were tried here and two were useless — animation counts (defeated by
the avatars' AO) and the clock at small N. What worked: exact UUID membership
for correctness, and a large sample for timing.

**One caveat that stands.** This was measured on a quiet region. Under sim load
script time slices shrink, and the 10 ms figure has only a 2x margin against the
frame. It is comfortable at eight seats and thin at sixteen.

**How the reasoning failed.** The claim rested on an assumption about
`run_time_permissions` being a gate rather than a notification, which was never
checked. It was then propped up with "AVsitter uses 2N+1 scripts precisely
because of this limitation; if cycling worked, it would have been done in 2015",
which is an argument from authority and turned out to be simply false. A
ten-minute in-world test settled what a paragraph of inference got backwards.

---

### The original rejection, superseded

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
* **The menu exists once per item, not once per seat.** Worth about 1 KB on a real notecard (1.1), so this is a clarity change, not a size one.
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
structure de-duplication alone saves about 5 % in bytes (1.1). Earlier figures here of a factor of six and then 28 % were line counts from a synthetic stress file, presented as if they were sizes.

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
and the partner would stand up when you sit down. They must therefore become two
lines with disjoint seats, which stays unambiguous because `POS` addresses by
pose **and** seat.

**No ID concept is introduced.** An earlier draft gave poses an identity
separate from their label (`Sitzen@0`); dropped 2026-07-28. The only genuinely
ambiguous case is a label mapping to two poses *for the same seat*, which
requires a slot-local `POSE` sharing a name with a `SYNC` that same seat takes
part in. That already yields two identically labelled buttons in the old
notecard, and it occurs zero times in the real sample. The converter renames the
second one and reports it. See [FORMAT.md](FORMAT.md) open point 3.

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
has to state what it chose. Same for any pose it renames to break a label
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
because `seat` drives it.

**Written 2026-07-29**, [`[QS]anim.lsl`](%5BQS%5Danim.lsl): **100 code lines**
against an estimate of 120 to 150, so ~5 KB at the project's 50 bytes per line,
against an estimated 8 KB. Predicted, not measured; the script exists so that
the figure can stop being predicted.

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

### 6.6 Per-operator dialog state in `menu`

The one place the singleton split needs new logic rather than moved logic.

Today every `sitB` instance serves exactly one operator, so `menu_page`,
`nav_stack`, `current_menu`, `menu_handle`, `menu_channel`, `page_map` and
`CONTROLLER` can be plain globals. A singleton serves several at once: two
people on a bed both browsing, plus an owner touching the furniture without
sitting, plus a HUD user.

#### Rejected: one shared listen channel

Dispatching by the avatar key from the `listen` event would save N handles and N
channel allocations. It is unsafe. `sitB` draws a fresh random negative channel
per dialog ([sitB.lsl:605]), and since a dialog cannot be closed
programmatically, a click on a stale window lands on a channel nobody listens to
any more and is silently dropped. On a long-lived shared channel that same click
would be **accepted** and executed against whatever state exists now. The random
per-dialog channel is the protection, not an implementation detail.

#### The record

```
OPS = [avatar, channel, handle, seat, curMenu, page, navCSV, lastAct]   strided 8
```

Two LSL-shaped decisions in there:

* **`navCSV` is a string**, because lists cannot nest. The back-navigation stack
  becomes a comma-separated list of menu indices.
* **`page_map` is not stored at all.** It is a render cache today; the singleton
  re-derives it from `curMenu` and `page` when a click arrives. One LSD read per
  click, once per click, and the nesting problem disappears with it.

`CONTROLLER` and `MY_SITTER`, which are two globals today, become the `avatar`
and `seat` fields of one record. That is a clearer split than the current pair,
where the difference only matters when `[QS]root-control` hands the menu to
somebody else.

#### Lifetime

A record is dropped, with `llListenRemove`, on any of:

1. **Standup**, for a seated operator.
2. **Re-open**, when the same avatar opens a new dialog. The old listen goes, a
   new channel is drawn. This is what `sitB` already does.
3. **Timeout**, for operators who walk away. Unavoidable: a dialog cannot be
   closed, so nothing signals that the window is dead.
4. **Cap exceeded**, evicting the least recently active. Proposed cap is seat
   count plus two, since every seat can have an occupant and a non-seated owner
   or HUD user can be operating as well.

**A deviation from the project's timer convention, stated openly.** The
event-driven preference cannot cover case 3, because there is no event. The
compromise is a sweep timer that is armed only while `OPS` is non-empty and
disarmed the moment it drains, so an idle piece of furniture still runs no
timer.

#### Cost

Record management, add, find by channel, evict and sweep, is an estimated 60 to
100 lines. That takes `menu` from the ~760 lines in 6.4 to roughly 840, still
the most headroom of the singletons.

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
| 1 | Real size of `[QS]anim`. **Written 2026-07-29**, 100 code lines, so ~5 KB predicted against the 8 KB estimate. Awaiting the one thing that cannot be done here: drop it in a prim and read the `used=` figure it prints at `state_entry`. Nothing else has to work for that. | Sharpens the projection in section 2; does not gate it, see below |
| 1b | Whether `menu` fits. Estimated ~840 lines / 42 KB after the adjust UI moves to `[QS]offset`, the authoring literals leave and per-operator state arrives, with a documented relief order if not. Not cheaply spikeable; the risk is in the line count, not the bytes-per-line, which is measured twice. | Sections 2, 6.4 and 6.6 |
| 1c | Placement vocabulary and ordering for the unified registration wire, and how visible the top-level registration race is in practice. See [REGISTRY.md](REGISTRY.md) section 8. | The section 2 principle |
| 2 | `llSetMemoryLimit` appears in **no** script in the repo. Without it every instance books the full 64 KB and the projection is void. Needs a peak measurement per script plus headroom, otherwise stack-heap collisions. | Section 2, and it is a win available today without any rebuild |
| 3 | ~~Per operator dialog state in a singleton `menu`.~~ **Designed 2026-07-28, see 6.6.** Still unproven in-world: the sweep timeout for operators who walk away, and whether the proposed cap of seats plus two is enough. | Section 6.3 |
| 4 | Collision rate in the existing stock: how often do identically named `POSE` entries occur across sitter blocks. **First real data point 2026-07-28: zero** in "BED ENGINE 2026", where seat 1 has no `POSE` lines at all and every coupled pose is correctly authored as `SYNC`. One well-built file is not a rate; more of the stock still needs counting. | Section 5, and therefore the sequencing choice in 5.4 |
| 4b | Divergence classes found in the same file that the converter must report: a menu carrying different flags per sitter (`MENU PRONE\|V` against `MENU PRONE`), and identical pose sets in different order within a menu. | Section 5.1 assumption 5 |
| 5 | LSD budget after de-duplication. Expected to be small, since 1.1 shows the duplication is scaffolding rather than data. Re-measure `Storage=` on the reference sofa with a converted notecard. | The "several pieces of furniture in one linkset" goal |
| 5b | **Deferred 2026-07-28.** One notecard or two: whether the machine-written `POS` lines move to a second card so the hand-edited one stays small (4.3). Not forced yet, since a two-seat file fits either way; a six-seater with full offsets would not. **Revisit when the converter is built**, because it has to choose an output shape anyway. Costs `boot` 40 to 60 lines for the second card. | The notecard editor limit on large furniture |
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

---

## 9. SLua

Researched 2026-07-29 from the wiki, the release notes and the feedback site.
Beta since December 2025, runs **only in SLua beta regions**, so nothing here is
shippable yet. LSL keeps working everywhere.

### The four questions that were blocking

| Question | Answer |
|---|---|
| How are events declared? | `LLEvents:on("touch_start", function(...) end)`. **Global handlers are dead**: the release notes say `touch_start()` "and friends no longer do anything". |
| Does `link_message` exist? | Yes, and **`id` is now a string**, not a key, "since it's most frequently used to pass string data rather than a UUID". |
| Does LinksetData exist? | Yes, as `ll.LinksetData*`. `ll.LinksetDataRead` returns `""` for a missing key, as LSL does. |
| **Do SLua and LSL coexist in one linkset?** | **Yes, and it is designed for.** The feedback thread on `LinksetDataRead` argues that `""` must keep deleting a key "to be compatible with LSL scripts sharing the linkset data in the same object", with a participant naming the case outright: "Legacy objects that we're enhancing." |

The last one is the important one: **migration can be incremental.** One script
at a time, plugins following at their own pace, rather than the whole plugin
landscape having to move in one release.

### The finding nobody asked for

**`ll.*` functions are 1-indexed.** From the release notes: "All
`ll.SomeFunction()` functions that accept or return an index into some other
object will be 1-indexed unless you're using `llcompat.SomeFunction()`."

QuickySitter is full of indices: link numbers, list positions, slot integers,
strided list arithmetic. A port that misses this produces off-by-one bugs that
compile cleanly and fail subtly. `llcompat.*` preserves the old behaviour and is
the safer choice for a port; new code can use `ll.*` deliberately.

### Two known issues worth watching

Both from the SLua Alpha feedback list, both touching this product directly:

* **"Failed to Perform Mandatory Yield error in long running script."** The
  permission-cycling loop (section 3) is exactly a long-running handler. At eight
  seats it is ~10 ms, so probably far from the limit, but the failure mode in
  SLua is apparently an *error* rather than a silent suspension.
* **"Erratic starts of halted SLua scripts when drag-copying the containing
  object."** Furniture is copied and sold for a living.

### What is not yet documented anywhere

The wiki has no page for `link_message` or LinksetData under SLua, and the
`Luau_Examples` page still shows the dead global-handler syntax. The GitHub repo
is the VM fork, not the SL bindings. Everything above came from release notes and
feedback threads, which means it is current but not authoritative, and the beta
says outright to expect changes.

**Correction:** an earlier note in this session cited `ll.Table2Json` /
`ll.Json2Table` as available. Those are a feature *request* on the feedback site.
The shipped API is `lljson.encode` / `lljson.decode`.

---

## 10. One prim, several seats

Measured in-world 2026-08-13 with `qs2/test/oneprim.lsl`, two avatars, one
unlinked cube. The question was whether the one-prim-per-seat rule that shapes
v1 is a platform limit or an artefact of how v1 seats people.

> **STATUS 2026-08-13: confirmed across four prim sizes by a third probe,
> `primsize.lsl`.** A single prim admitted a second avatar at 0.5, 1.0,
> 1.5 and 2.0 m on X, with the sit-target sequence held constant. Prim
> size is not the limit and sofa scale is fine.
>
> ONE UNEXPLAINED FAILURE REMAINS. The same code refused a second sitter
> in one specific hand-built 2 m prim, which is what sent this down a
> prim-size hypothesis in the first place. That prim's other dimensions
> and its shape were never recorded. Until it is explained, assume some
> prim property can block admission and find out which before shipping
> anything that depends on it.
>
> Five earlier explanations were wrong, every one reasoned from how SL
> "should" behave rather than measured: that the target must be re-armed,
> that it must be re-armed to a *different* value, that moving the avatar
> interfered, that the camera did, that prim size governed.

### It is an artefact

All three gates passed on the first run.

| | Question | Result |
|---|---|---|
| Q1 | Does re-aiming the sit target eject or drag the avatar already on it? | Neither. A stayed at `<0, 0, 0.90>` while the target moved to slot 1. |
| Q2 | Can a second avatar then sit on the same prim? | Yes. B landed on link 3. |
| Q3 | Can both be positioned independently by link? | Yes. `<0, 0, 0.55>` and `<0.7, 0, 0.55>`, exactly as set. |

A sit target binds one avatar per prim **for the instant of sitting only**.
Afterwards the avatar is a link of its own, and `PRIM_POS_LOCAL` on that link
is authoritative. `seat` already does this in `move_occupant`, which is why
this costs less to adopt here than it would have in v1.

### Two findings that were not the question

**The sit target only places the FIRST arrival.** B never landed on the
re-aimed slot `<0.7, 0, 0.55>`. Two runs of the identical script put B on
`<0.34, -0.24078, 0.88>` and on `<0.12350, -0.33743, 0.90965>`: different
unrounded values from the same code, which is SL's own click-relative
placement and nothing else. **That answers the seat-choice question** — the
landing position of arrival 2 carries the click, so choosing a seat by click
survives on one prim, and continuously rather than per prim. Re-aiming
the target between arrivals is therefore pointless: what actually matters is
only that the prim stays sittable, and that `move_occupant` places each arrival
afterwards. The design is a step simpler than the sketch it came from.

The visible cost is a one-frame jump: arrival 2 and later appear wherever SL
dropped them until the pose applies.

**SL adds +0.35 to the sit target.** Target `Z 0.55` produced a link position of
`0.90`. That is what v1's `-0.4` in `set_sittarget` compensates (sitA.lsl:460),
and it settles the question from earlier the same day: the constant was never
arbitrary. It stays removed here regardless, because `move_occupant` overwrites
the position on every pose apply, so the target value is only ever visible in
the instant before the first pose.

Note the asymmetry: a position set BY SCRIPT lands exactly (Q3 returned the
values we wrote), a position obtained via a sit target does not.

### What it would cost

`llAvatarOnLinkSitTarget` reports one avatar per prim and named only the first
of the two throughout. `seat` uses it in exactly two places, and both are load
bearing:

- `rescan_occupancy` (seat.lsl:413), which is how occupancy is discovered at all
- the `seat_stop` guard (seat.lsl:356), which is what stopped the standup
  animation-permission dialog

Both would have to be rebuilt on `CHANGED_LINK` differences: keep the previous
agent-link list, diff it, and match arrivals to free seats. That is not more
code, but it is a different failure mode — a missed event desynchronises the
table, where the current lookup re-derives the truth every time.

Also lost, and not recoverable:

- **per-seat camera**, since `llSetCameraEyeOffset` is prim-bound
- **seat choice by click point**, since there is only one prim to click
- **`#SET-slot` prim-description pinning**, which has nothing left to pin

And one risk that cannot be designed away, only locked: two avatars sitting
inside the same frame. The current model has the sim arbitrate that, one target
per prim; a single prim hands the arbitration to us.

### Not now

Stage 1 is still being brought up and `seat` is the script under repair. This is
recorded so the measurement is not lost, not scheduled. It is additive when it
comes: a build with one seat prim per avatar keeps working either way, since
the change is in how occupancy is discovered, not in how poses are applied.

### How SL places arrival 2, measured

Four sizes, sit-target sequence identical throughout (open `<0, 0, 0.55>`,
re-arm `<0.7, 0, 0.55>` after arrival 1). Arrival 1 always landed exactly on
the target plus the +0.35 SL adds. Arrival 2 landed:

| prim X | half width | arrival 2 x | arrival 2 y |
|---|---|---|---|
| 0.5 | 0.25 | 0.066 | -0.34 |
| 1.0 | 0.50 | 0.424 | -0.34 |
| 1.5 | 0.75 | -0.591 | -0.34 |
| 2.0 | 1.00 | 0.105 | -0.34 |

**y is constant at -0.34** across every size and every run: a fixed lateral
offset, carrying nothing. **x tracks the click along the prim's long axis** and
stays inside the half width, so its usable range grows with the furniture. The
negative value at 1.5 m was a deliberate click on the left half.

That is the shape seat choice needs. Discard the magnitude of the offset from
arrival 1, take the position along the long axis, and match it against the seat
layout — a 2 m sofa gives roughly ±1.0 of range, ample for three seats. An
earlier reading of the same data as "a fixed radius, only the angle varies" was
wrong; it was drawn from three samples that happened to be at similar sizes.

Not yet measured: whether x saturates near the ends, and how it behaves on a
prim that is long on Y rather than X.

### The real limit: how far out arrival 2 may click

Reported from in-world 2026-08-13: **clicking at the outer end fails to seat
arrival 2; clicking near the middle succeeds.** Same prim, same script, same
moment.

That explains every failure in this investigation at once, and the cause was
the test instructions rather than the code. `sitpick.lsl` came with "right-click
the LEFT or RIGHT end", `oneprim.lsl` and `primsize.lsl` did not. The runs
carrying that instruction are exactly the runs that failed, including the
hand-built 2 m prim that sent this chasing prim geometry.

It fits the measurements. Every successful arrival-2 x, across all sizes:

```
0.066   0.105   0.1235   0.34   0.34   0.424   -0.591
```

None above roughly 0.6, while the outer end of a 2 m prim is x = 1.0. So there
appears to be a maximum offset beyond which SL will not seat an additional
avatar at all.

This is a worse constraint than prim size would have been, because it does not
limit how large the furniture may be — it limits **how far out a seat can still
be clicked into**. A seat beyond the reach can still be USED, since occupants
are moved by link afterwards; it just cannot be chosen by clicking near it.

**Open, and the number that decides how much this hurts:** whether the limit is
absolute or scales with the prim. Measure by clicking progressively further out
at 2.0 m and again at 1.0 m and recording the largest x still admitted. A failed
sit fires no event, so only a human can observe it.

### The click action is the lever, and the reach limit was a sampling artefact

With the prim's click action set to sit on the object, arrival 2 was seated
five times in a row on a 2 m prim at:

```
-0.90721   -0.82602   -0.15192   0.06047   0.67673
```

That is nearly the full half width of ±1.0, so **there is no reach limit**. The
"nothing above 0.6" reading in the section above came from seven samples that
happened to cluster, not from a constraint. It is left standing as a record of
how a plausible limit can be read out of too little data.

The variable that actually governed it is the click action. A prim set to sit
on click carries the click point through; the default action does not, and that
is why deliberate end-clicks failed. The engine can set this itself with
`llSetClickAction(CLICK_ACTION_SIT)`, so it is a script decision rather than
something a builder has to remember.

**The cost is the menu.** v1 opens the menu on touch, and with the click action
set to sit, a left click seats instead. Stock AVsitter has the MTYPE/ETYPE click
modes for exactly this conflict, and v2 has not built them (STATUS.md). So
single-prim seating and touch-to-menu compete for the same gesture, and
whichever way that is resolved has to be resolved deliberately.

### A linkset is not a problem, it is the fallback

Raised while weighing whether to do this before finishing stage 1: what happens
if somebody still builds a multi-prim linkset?

Nothing, if the two modes coexist rather than replace each other:

```
prims carrying #SET-slot descriptions  ->  classic binding, one prim per seat
                                           (per-seat camera and per-prim
                                           clicking both survive)
otherwise                              ->  everyone on one prim, seat chosen
                                           from the click position
```

So `resolve_bindings` does not get discarded, it becomes the branch that runs
when the builder supplied seat prims. Every piece of furniture built to date
keeps working untouched, and single-prim seating is an ADDITIONAL mode for new
builds rather than a migration. That makes the change smaller than the estimate
above, and less urgent, because nothing depends on it.

Two things already generalise for free, both because `seat` is a singleton
rather than one script per seat prim: `av_link` finds agents by walking the top
link numbers regardless of prim count, and `move_occupant` already converts
through the seat prim's own `PRIM_POS_LOCAL`.

Two things would need deciding:

- **Click action is per prim.** `llSetClickAction` affects only the prim its
  script is in, so a linkset needs `PRIM_CLICK_ACTION` pushed across the links,
  or only part of the furniture will seat on click.
- **What SL does when a prim in a linkset has no sit target is UNMEASURED.** The
  only measurement is that a lone prim without one cannot be sat on at all.
  Whether a linkset falls back to the root's target is not known, and after this
  investigation it will not be guessed.

---

## 11. Stage 2: the ITEM token, as an ADDITION to AVpos

Decided 2026-08-14. This supersedes the ITEM described in §4: that one belonged
to the cancelled format change and grouped a NEW notecard syntax. This one is a
single additive token on the EXISTING AVpos format, in line with the decision
that cancelled §4 - old notecards stay valid unchanged and mean "one implicit
item".

### The insight: the mapping already exists

v1 already supports several pieces of furniture in one linkset, through the SET
mechanism: a SET number in the notecard, `#<SET>-<slot>` in the prim
description, the SET field in 90045. What makes it expensive in v1 is that each
SET needs its OWN full script set. ITEM is that mechanism served by the one
singleton set: **a named SET, all items out of one notecard.**

### Notecard

```
ITEM Sofa                <- item index 0
SITTER 0|Girl|F          <- global channel 0, local slot 0
SITTER 1|Guy|M           <- global channel 1, local slot 1
...poses, menus...

ITEM Sessel              <- item index 1
SITTER 0|Solo            <- global channel 2, local slot 0
...
```

`ITEM <name>` opens a group; every SITTER until the next ITEM belongs to it.
SITTER numbering restarts per item (it is the local slot). A notecard with no
ITEM line is one item, index 0, unnamed - byte-identical behaviour to today.

### Prim addressing: the name is the address

The prim description carries the ITEM NAME, and the number disappears from the
builder's world entirely:

```
#Sofa-0     seat 0 of the Sofa
#Sofa-1
#Sessel-0
```

Parsing is a two-way split on the field before the `-`: an integer means the
legacy `#SET-slot` reading (existing furniture, v1 muscle memory), anything
else is an item name from the notecard. The index survives only internally and
on the wire (90045 field 3), where plugins expect a number anyway.

The name pays off where humans read: the prim description becomes
self-documenting (`#Sofa-1` says what it is, `#0-1` says nothing), the menu
title can show `[Sofa]`, the seat picker and DUMP output get real names.

**A name that matches no item is a boot-time WARNING, never a silent free
prim.** `#Soffa-0` must produce "prim description names unknown item 'Soffa'"
in the self-check. The alternative - the prim quietly falling into the free
pool - is exactly the silent-failure class this project spent a week digging
out of.

### Storage and scoping

LSD gains one table and one per-channel field:

```
qs:item:<idx>   "<name>|<firstChannel>|<channelCount>"
```

(or the item index packed into qs:sitter:<ch>; decided at build time, whichever
keeps boot's writer simpler). Channels stay globally numbered exactly as today,
so every existing qs:p / qs:occ / qs:cur key and every QSO offset key is
untouched.

What re-scopes from "the whole linkset" to "within the item":

| mechanism | note |
|---|---|
| SYNC broadcast (start_entry's S branch) | couples only the item's channels |
| seat pick, gender swap, [SWAP] | within the item |
| menu title, roster (90045 field 4) | the item's channels |
| 90045 field 3 | the item index instead of constant -1 |

That last row is the compatibility story: **to a plugin, a linkset with two
items looks exactly like two v1 SETs**, a shape stock AVsitter and the HUD
chain already understand. No new wire contract.

### Open points, to be settled while building

1. **Unpinned prims belong to item 0**, preserving today's implicit behaviour.
   From the second item on, pinning is effectively mandatory; the self-check
   should say so when it sees >=2 items and unpinned sit-capable prims.
2. **`#<name>` without a slot** marks a prim as "belongs to this item, slots
   assigned automatically" - the bridge to single-prim items (DESIGN §10), one
   prim carrying all of an item's seats.
3. **Global cfg fields stay global in the first pass** (BRAND, CUSTOM_TEXT,
   AMENU, DFLT). Per-item overrides are a later, additive step.
4. **hudproxy's six-sitter cap is per linkset, not per item.** Two four-seat
   items exceed it; the HUD kit has to decide whether to raise or scope it.
5. **SPOT (pose-by-clicked-cushion) docks here later**: it is the same
   resolution chain one level finer (item -> seat -> spot), deferred by
   decision 2026-08-14 pending the cross-axis landing measurement.

### Touch points

boot's parser (the fork in qs2) learns the ITEM line and the name->index table;
seat's resolve_bindings learns the name reading and the item column in SEATS;
core's S branch, regender and swap learn the channel-range scope; menu learns
the item title and scoped seat pick. The wire does not change.

### 11.1 One notecard per item: `QS#<Name>` (SPEC, not built)

Agreed 2026-08-16, to be built later against this spec. A boot-only change:
seat, core and menu read the LSD schema and cannot tell how many cards it
came from.

**The pairing rule.** An item is a PRIM plus a CARD joined by one name: a
prim whose description pins `#Sofa` pairs with a notecard named
`QS#Sofa`. The card name is LITERALLY `QS` + the description pin, so
the match needs no name surgery on either side (`#` is legal in inventory
names; the Firestorm bridge ships as `#Firestorm LSL Bridge`). The
description already carries the binding today; the same name now also
fetches the content. Both halves copy between builds - move the prim, drop
the card, done. `#Sofa-0`/`#Sofa-1` (one prim per seat) collapse onto the
same item exactly as today, pairing with the one `QS#Sofa` card.

**Naming.** The BASE card keeps the legacy name `AVpos` - that name cannot
be retired without breaking every existing build and workflow. Everything
NEW deliberately avoids the AVsitter brand (trademark policy, and the
scripts are `[QS]*` anyway), hence `QS#<Name>`. The prefix is mandatory:
furniture inventories are full of landmark and instruction notecards, and a
stray card named just "Sofa" must never silently become an item. Side
effect: every pose card sorts together in the inventory.

**What each card contains.** A `QS#` card is SITTER blocks with local
slot numbers, poses, positions, OVERLAYs - the same dialect as today's ITEM
block, without the ITEM token. The card says how many seats the item has
(its SITTER blocks); the description says where it lives. Channel order is
link order of the item prims: deterministic, no numbering in card names.

**AVpos stays base + root menu.** Global directives (BRAND, VERBOSE, onSit,
CUSTOM_TEXT, ...) live ONLY there; in a `QS#` card they are an error with
a message, because card order must never decide a global. A build with no
QS# cards behaves exactly as today, nothing migrates.

**Conflict rules.**

| found | rule |
|---|---|
| description, no card | today's path: the base card may declare the item via ITEM token |
| card, no matching description | warn, ignore the card |
| both, plus an ITEM token of the same name in AVpos | error with a message; the card wins nothing silently |

**Re-seed.** `qs:boot:asset` becomes the joined asset-key chain of AVpos
plus every paired QS# card, so swapping ONE item card triggers the
re-seed. CHANGED_INVENTORY already fires on card swaps.

**Why bother:** the viewer's notecard editor truncates near 48 KB, which a
multi-item vehicle card WILL hit; per-item cards dissolve that limit and
make items a reusable library.

**Before building: measure boot.** It is the second-tightest script
(~58 KB used at the 1.27 fork). One llGetFreeMemory print at parse start,
numbers over guesses; the addition is control flow (card list, EOF
hand-over, key chain), estimated 1-2 KB.

## 12. OVERLAY: extra animations riding on a pose

Third-party plugins exist for hand poses (grip anims so held props sit right)
and face animations. Mechanically they are ONE feature: while pose X plays on
sitter S, additionally play animation set Y. v2 integrates that as a notecard
line instead of a plugin script.

The saving is per-furniture script count, on top of the sitter
consolidation: those plugins ship n hand scripts + n face scripts + one
controller = 2n+1 (a two-seater: 5 scripts, 320 KB). With OVERLAY the same
furniture runs the feature at zero extra scripts - a two-seater lands on 4
scripts total against 10 before (5 sitter engine: n sitA + n sitB + boot,
plus the 5 plugin scripts), 256 KB against 640. Scripts that exist
identically on both sides ([QS]prop, the authoring-time adjuster) are not
counted.

### Syntax

    OVERLAY <posename>|<anim>[|<anim>...]

Inside a SITTER block, AFTER the pose's own line - the same ordering rule as
`{posename}` splices, and for the same reason: the lookup is against the
entries seeded so far. The pose name matches bare or `P:`-prefixed, exactly
like the splice lookup. Stock AVsitter ignores the unknown keyword, so cards
stay portable in the read direction.

### Storage and flow

    qs:ov:<ch>:<i>    SEP-joined anim list, keyed by the ENTRY INDEX

Written by boot at seed time, only for entries that declare overlays: a card
without OVERLAY lines costs nothing anywhere. core appends the set as field 5
of the QSC_APPLY row (row_for). seat starts the new set with the same
per-avatar permission it uses for the pose anim, and retires whatever fell
out of the previous set after the shared overlap sleep - an anim present in
both sets is never stopped, so it cannot flicker.

SYNC is covered without any extra mechanism: start_entry emits one row per
participating seat, each from that seat's OWN channel entry, so each
participant gets their own overlays - the hand-pose plugin's per-sitter
couple lines map 1:1.

### Deliberately not built

- A re-trigger timer. The suspicion was that face anims run out and need
  re-firing (the plugin's numeric third field, `ANIM name|B1|3`, read like
  an interval). Resolved 2026-08-15: these animations LOOP, so a started
  overlay stays up until the pose changes and the field is moot for us.
  Should a non-looping overlay anim ever turn up, this is where the timer
  would go - in seat, gated on an active overlay, one-shot per fire.
- Alias tables (`face = B1 | BJ1`): the creator writes anim names directly.
  Revisit only if a real card repeats one anim across dozens of lines.
