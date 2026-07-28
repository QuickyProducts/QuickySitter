# QuickySitter v2 notecard format, draft spec

**Status: draft.** No parser exists. Companion to [DESIGN.md](DESIGN.md), which
covers the runtime side and the migration path.

**Design goal, stated by the product owner:** a new system only has a chance if
it is easy to understand. Everything below is subordinate to that. Where
brevity and clarity conflict, clarity wins; where a rule saves a few characters
but adds a concept, the rule loses.

A creator needs **four words** for a normal piece of furniture:

```
SEAT   MENU   POSE   POS
```

`ITEM` appears only when someone actually puts two pieces of furniture into one
linkset.

---

## 1. Lexical rules

1. **One directive per line.** The first word is the token.
2. **Fields are separated by `|`.** Surrounding whitespace is trimmed.
3. **Indentation and blank lines are decoration** and carry no meaning. The
   viewer's notecard editor mangles whitespace and copy-paste does the rest, so
   nothing structural may depend on it.
4. **Order matters only for display order** and for `SEAT` (fill order). A
   directive never depends on how far it is from another one, only on which
   `MENU` or `ITEM` was most recently opened.
5. Lines starting with `#` are comments. Empty lines are ignored.
6. Token names are upper case and matched exactly. (Deliberately strict: the
   1.26 measurement showed lenient matching cost over 600 bytes for one token.)

---

## 2. The four core tokens

### `SEAT <name>[|<gender>]`

Declares a named occupant slot. Declaration order is the fill order and the
order in the seat picker and swap menu.

```
SEAT Links|F
SEAT Rechts|M
```

The name is the key that `POSE` and `POS` lines reference. It is local to its
`ITEM`, so `Links` in `Bett` and `Links` in `Sofa` are different seats.

Declaring seats rather than inferring them from the pose lines buys four things:
fill order, seat count (independent of which pose is running), typo protection
(a misspelt seat is a parse error instead of a silent phantom), and one place to
hang per-seat properties.

### `MENU <path>`

Opens a menu. Subsequent `POSE` lines belong to it until the next `MENU`.

```
MENU Kuscheln
MENU Kuscheln/Sanft
```

`/` nests. **The button in the parent menu is created automatically.** There is
no separate "make this menu reachable" directive; today's `MENU` versus
`TOMENU` split is the single most reported source of "my menu does not show up"
and it disappears here.

Poses declared before the first `MENU` belong to the top level.

**`MENU <path>|hidden` suppresses the button.** The menu exists and can be
reached from a `SEQUENCE` or by a plugin, but nothing links to it.

This is a special case and it is here because a real notecard needs it. In the
"BED ENGINE 2026" sample, `MENU HIDDEN BJ` carries no `TOMENU` in either sitter
block and is reached only through `SEQUENCE Propped`. Deliberately unreachable
menus are a real authoring technique, and the automatic parent button would
otherwise expose them. A converter without this flag silently changes the menu
a customer sees.

### `POSE <label> | <seat>=<anim> [| <seat>=<anim> ...]`

One line per pose, naming every participating seat.

```
POSE Löffel | Links=sleep_spoonA | Rechts=sleep_spoonB
POSE Lesen  | Links=read_sit
```

**Whoever is named takes part; whoever is not named is not touched.**
Independence is the default, coupling is written down. This replaces the
`POSE` versus `SYNC` distinction entirely: a couple pose is a line with two
seats, a solo pose is a line with one.

**Shorthand, single seat only.** If the `ITEM` declares exactly one seat, the
seat name may be omitted:

```
SEAT Sitz
POSE Sitzen | chair_idle
```

**Decided 2026-07-28: allowed.** Single-seat furniture is the most common shape
there is, and the shorthand makes the line character-identical to today's AVpos
apart from spacing around the separator, so for those creators the format change
reads as no change at all.

The price is that **adding a second seat later rewrites every `POSE` line**.
That is acceptable because the failure is loud rather than silent: once a second
`SEAT` is declared, a `POSE` line without `=` cannot be resolved and is a parse
error with a line number. Anyone adding a seat also has to set offsets for every
pose on it, so it was never a five-minute edit.

### `POS <pose> | <seat> | <position> | <rotation>`

The position of one seat in one pose.

```
POS Löffel | Links  | <0.0,0.2,0.4>  | <0,0,90>
POS Löffel | Rechts | <0.0,-0.2,0.4> | <0,0,90>
POS Lesen  | Links  | <0.0,0.0,0.42> | <0,0,0>
```

**Written by the adjuster, not by hand.** Every line is self-contained: it
repeats the pose name instead of inheriting it from the line above. That is
verbose, but the verbosity costs a human nothing (nobody types these) and it
means the block survives reordering, partial copy-paste and a machine appending
to the end.

Self-contained means *within its item*. Like every other directive, a `POS` line
belongs to the most recently opened `ITEM` (section 3), which is what keeps seat
names local and unambiguous.

**The single-seat shorthand does not apply here.** A `POS` line always names its
seat, even when the item has only one. The shorthand exists to spare a human
typing; nobody types these.

Both `<pose>` and `<seat>` are resolvable names from the structure above, so a
typo is a parse error with a line number. Today a mistyped `{Name}` is a silent
no-op that the creator discovers in-world as "the pose sits wrong".

**Frame of reference:** the offset is local to the prim of that seat. There is
exactly one frame and therefore no `LROT` / `REFERENCE` token, and no inter-frame
conversion at runtime. Rotating or relinking the furniture does not move poses.

**Offsets stay in the notecard. Decided 2026-07-28.** Moving them into LSD alone
was considered and rejected; the notecard remains the source of truth and LSD
remains a derived cache. See DESIGN.md section 4.3 for the reasoning, which is
about durability rather than size.

---

## 3. `ITEM` and prim binding

### `ITEM <name>`

Starts a new piece of furniture. **Everything after it belongs to it** until the
next `ITEM`: seats, menus, poses and position lines alike.

```
ITEM Bett
SEAT Links|F  | PRIM bett_l
SEAT Rechts|M | PRIM bett_r

MENU Kuscheln
POSE Löffel | Links=sleep_spoonA | Rechts=sleep_spoonB
POSE Lesen  | Links=read_sit

POS Löffel | Links  | <0.0,0.2,0.4>  | <0,0,90>
POS Löffel | Rechts | <0.0,-0.2,0.4> | <0,0,90>
POS Lesen  | Links  | <0.0,0.0,0.42> | <0,0,0>

ITEM Stuhl
SEAT Sitz

POSE Sitzen | chair_idle

POS Sitzen | Sitz | <0.0,0.0,0.42> | <0,0,0>
```

Item scoping is what makes seat names local. Two items may both have a seat
called `Sitz` without colliding, and a `POS` line naming `Sitz` is unambiguous
because it belongs to exactly one item.

**`ITEM` is optional.** A notecard without it describes one piece of furniture
that binds to the whole linkset, which is exactly what every classic AVpos
means. Most creators will never type the word.

### Binding

An `ITEM` binds to every prim carrying its **name**. Prim name and prim
description are the only two rez-stable and relink-stable identifiers in SL;
link numbers do not survive a relink and prim UUIDs do not survive a rez.

`PRIM <primname>` on a `SEAT` is the override, needed only where the assignment
would otherwise be ambiguous, that is on multi-seat items. Without it, seats
are assigned to the item's prims in link order.

SL allows one sit target per prim, so an item with N seats needs N prims. This
is the same hard limit that produces today's "not enough prims for required
SitTargets".

Because storage is namespaced per item, two items in one linkset are isolated by
construction. `SET` is not removed so much as never created: the thing it tried
and failed to do is now structural.

---

## 4. Token inventory

All 27 tokens the current parser accepts, with their disposition.

### Replaced

| Today | v2 | Note |
|---|---|---|
| `SITTER` | `SEAT` | named, item-local, no global slot numbering |
| `POSE` | `POSE` | new syntax, names its seats |
| `MENU` | `MENU` | path-based nesting |
| `{Pose}<p><r>` | `POS` | self-contained line, resolvable names |

### Removed without replacement

| Token | Why |
|---|---|
| `SYNC` | coupling is structural, it is who appears in the `POSE` line |
| `TOMENU` | the parent button is automatic |
| `SET` | two items are two items |
| `LROT` | one frame of reference per seat |

### Carried over, semantics unchanged

These are not part of this draft's redesign. They are listed so the spec cannot
be mistaken for complete.

| Token | What it is |
|---|---|
| `BUTTON` | menu entry that fires a link channel |
| `SEQUENCE` | pose sequences; follows the same coupling rule as `POSE` |
| `PROP1` `PROP2` `PROP3` | prop rows (11 fields since 1.25) |
| `MTYPE` `ETYPE` | menu and click modes |
| `SWAP` | seat swap behaviour |
| `AMENU` `ONSIT` `DFLT` | menu and sit behaviour flags |
| `SELECT` `ADJUST` `HELPER` | feature and access gates |
| `ROLES` | RLV designations |
| `TEXT` | floating text |
| `KFM` | keyframed-motion flag |
| `BRAND` | branding string |
| `VERBOSE` `WARN` | diagnostics |

**Open, needs a pass through the parser:** several of these are today scoped to
the current `SITTER` block. Each one has to be assigned to either the `SEAT` or
the `ITEM`. That is mechanical but it has not been done, and the semantics of
`ADJUST`, `AMENU`, `DFLT`, `ONSIT`, `ROLES` and `SELECT` were not revisited for
this draft.

Note there is **no** `CAMERA` token; camera is driven at runtime over 90202, not
from the notecard.

---

## 5. Worked example

A two-seat bed with a submenu, one couple pose and one solo pose.

### Today

```
SITTER 0|Links|F
TOMENU Kuscheln
MENU Kuscheln
SYNC Löffel|sleep_spoonA
POSE Lesen|read_sit
{Löffel}<0.0,0.2,0.4><0.0,0.0,90.0>
{Lesen}<0.0,0.0,0.42><0.0,0.0,0.0>

SITTER 1|Rechts|M
TOMENU Kuscheln
MENU Kuscheln
SYNC Löffel|sleep_spoonB
{Löffel}<0.0,-0.2,0.4><0.0,0.0,90.0>
```

### v2

```
SEAT Links|F
SEAT Rechts|M

MENU Kuscheln
POSE Löffel | Links=sleep_spoonA | Rechts=sleep_spoonB
POSE Lesen  | Links=read_sit

POS Löffel | Links  | <0.0,0.2,0.4>  | <0,0,90>
POS Löffel | Rechts | <0.0,-0.2,0.4> | <0,0,90>
POS Lesen  | Links  | <0.0,0.0,0.42> | <0,0,0>
```

At this size the two are about the same length. The difference appears with
scale, because the menu skeleton stops being repeated per seat.

### Measured on the existing stress file

`qs/test/AVpos.stress3120.txt`, 6 sitters, counted by line type:

| | today | v2 |
|---|---|---|
| `POSE` | 3120 | 520 |
| `MENU` | 156 | 26 |
| `TOMENU` | 156 | 0 |
| **structure lines** | **3432** | **546** |

Factor 6.3, which is exactly the sitter count. **That file is synthetic and has
6 offset lines**, so it measures the structure saving and nothing else.

### Measured on a real notecard

"BED ENGINE 2026", 2 sitters, 193 poses in seat 0 (179 coupled plus 14 solo)
and 179 in seat 1:

| | today | v2 |
|---|---|---|
| structure lines | 444 | 214 |
| `POS` / `{}` lines | 372 | 372 |
| **total** | **816** | **586** |

Structure saves factor 2.07, again exactly the sitter count. **Offsets save
nothing**, being inherently one per pose per seat. The real-world saving is
therefore **28 %**, not a factor of six.

**And that reorders the priorities.** If the offsets leave the notecard
altogether and live only in LSD, the same file drops to **214 lines, a 74 %
saving**. Moving them out is worth more than the entire structure
de-duplication. What section 2 lists as a direction of travel is in fact the
main lever on the notecard editor limit.

---

## 6. Open points

1. ~~Single-seat shorthand.~~ **Decided 2026-07-28: allowed**, for `POSE` only
   and never for `POS`. See section 2.
2. **Scoping of the carried-over tokens** to `SEAT` versus `ITEM`. Mechanical,
   not done.
3. ~~Pose identity versus display label.~~ **Dropped 2026-07-28.** There is no
   ID concept and no separation of label from identity.

   The case it existed for: a label that maps to more than one pose *for the
   same seat*, which can only arise if a slot-local `POSE` shares a name with a
   `SYNC` the same seat takes part in. That already produces two identically
   labelled buttons in the old notecard, and it occurs zero times in the "BED
   ENGINE 2026" sample.

   Resolution: **the converter renames the second one and says so** in its
   report, so the creator can name it properly afterwards. Every label is then
   unique within its item and seat, `POS <pose> | <seat>` always resolves, and
   the format carries one special case fewer.
4. ~~The engine script name.~~ **Decided 2026-07-28.** The seat engine is split
   into `[QS]core` (what gets played) and `[QS]seat` (who sits where);
   `[QS]control` was rejected because "control" already means *who operates the
   menu* in this codebase. See DESIGN.md section 2.
