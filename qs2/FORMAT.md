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

This is the most common furniture shape there is, and the shorthand makes the
line identical to today's AVpos. *Marked as revocable:* it is a special case,
and special cases are what erode "easy to understand". Drop it if it causes one
support question.

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

Both `<pose>` and `<seat>` are resolvable names from the structure above, so a
typo is a parse error with a line number. Today a mistyped `{Name}` is a silent
no-op that the creator discovers in-world as "the pose sits wrong".

**Frame of reference:** the offset is local to the prim of that seat. There is
exactly one frame and therefore no `LROT` / `REFERENCE` token, and no inter-frame
conversion at runtime. Rotating or relinking the furniture does not move poses.

**Direction of travel:** this block is 100 % machine written and is by far the
largest part of a real notecard. It is the natural first candidate to live only
in LSD, with the notecard carrying it as export and backup only. See DESIGN.md
section 4.3.

---

## 3. `ITEM` and prim binding

### `ITEM <name>`

Starts a new piece of furniture. Everything after it (seats, menus, poses)
belongs to it, until the next `ITEM`.

```
ITEM Bett
SEAT Links   | PRIM bett_l
SEAT Rechts  | PRIM bett_r
MENU Kuscheln
POSE Löffel | Links=sleep_spoonA | Rechts=sleep_spoonB

ITEM Stuhl
SEAT Sitz
POSE Sitzen | chair_idle
```

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

Factor 6.3, which is exactly the sitter count.

**Two honest caveats.** That file has identical blocks across sitters; a real
file whose menus diverge saves less. And `POS` lines do not de-duplicate at all,
being inherently per pose per seat, so in a fully adjusted notecard they come to
dominate. Which is the argument for moving them out of the notecard entirely.

---

## 6. Open points

1. **Single-seat shorthand** (section 2, `POSE`). Included on the product
   owner's default recommendation, explicitly revocable.
2. **Scoping of the carried-over tokens** to `SEAT` versus `ITEM`. Mechanical,
   not done.
3. **Pose identity versus display label.** The migration path requires that a
   pose is identified by (label, seat set) rather than by label alone, because
   two same-named `POSE` entries in different sitter blocks are independent
   today. The converter emits internal IDs on collision. This spec has not yet
   settled how such an ID is written in the notecard. See DESIGN.md section 5.2.
4. **The engine script name.** DESIGN.md calls the singleton `[QS]station`,
   which no longer matches `ITEM`. Proposal: `[QS]sit`, since it is the
   successor of `sitA` and owns the seat lifecycle. Not decided.
