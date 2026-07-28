# QuickySitter v2 menu registration, draft spec

**Status: draft.** No implementation exists. Third document alongside
[DESIGN.md](DESIGN.md) (runtime and migration) and [FORMAT.md](FORMAT.md)
(notecard syntax).

This is the mechanism behind the requirement in DESIGN.md section 2:

> `menu` knows how to render a registry. It does not know what an adjuster is.

Every menu entry that is not a pose from the notecard is **registered at
runtime by the script that owns it**. `menu` carries no literal for `[HELPER]`,
`[QUICKYHUD]`, `[NEW]`, `[SAVE]`, `[DUMP]`, `[ADJUST]` or anything else a
creator tool contributes.

---

## 1. What it replaces

Three half-registries exist today, each with a fixed destination baked into the
receiver:

| Today | Number | Lands in | Payload |
|---|---|---|---|
| `QSPLUG_REGISTER` | 90212 | `[OPTIONS]` | `label\|chan\|scriptName` |
| `QSADJ_REGISTER` | 90213 | `[ADJUST]` | `label\|chan\|scriptName\|flags` |
| `QSADJ_UNREGISTER` | 90216 | | |
| hudadmin `menuplus` | | its own entry | own mode |

Three ways to do one thing. v2 has one wire with a **placement** field, and the
placement is a menu path of the kind [FORMAT.md](FORMAT.md) already defines.

---

## 2. The wire

Receiver in v2 is `menu` (it is `sitB` today).

### Register

```
num = 90212
msg = <label>|<channel>|<owner>|<flags>|<path>
id  = (reserved, empty)
```

| Field | Meaning |
|---|---|
| `label` | Button text. Also the message sent back on click. |
| `channel` | Link-message number the click is delivered on. |
| `owner` | `llGetScriptName()` of the registrant. Identity and dedupe key. |
| `flags` | Bit 0: owner-only, the entry renders only for the object owner. |
| `path` | Where it lands. Empty means top level; otherwise a menu path such as `Extras/Werkzeuge`. |

### Unregister

```
num = 90216
msg = (empty)
id  = <owner>
```

Drops **every** entry belonging to that owner. A script does not have to
remember what it registered.

### Click delivery

When the entry is clicked, `menu` sends:

```
num = <channel from the registration>
msg = <label>
id  = <key of the avatar who clicked>
```

Which is what `sitB` does today, so plugin click handlers need no change.

---

## 3. Backward compatibility

The numbers are deliberately the existing ones, and the payload is the existing
one with `path` appended. Older registrants keep working untouched:

| Payload received | Interpreted as |
|---|---|
| 3 fields on 90212 | `flags = 0`, `path = [OPTIONS]` |
| 4 fields on 90213 | `path = [ADJUST]` |
| 5 fields on 90212 | as specified above |

`[QS]objectadjust`, `qs/examples/[QS]plugin-example.lsl` and any third-party
plugin written against `PROTOCOL.md` therefore run on v2 without modification.
90213 survives as a legacy alias for "register with `path = [ADJUST]`".

---

## 4. Placement

**A path that does not exist is created.** It exists only while at least one
entry lives at it, and disappears with the last one. This is what makes
`/5 cleanup` a real removal rather than a hidden state: the menu is gone because
nobody is holding it open.

**Ordering inside a menu:** notecard entries first, in notecard order, then
registered entries in registration order. No sort keys are offered. Determinism
matters more here than control, and a creator who wants a specific position has
the tool in the next paragraph.

### Label collisions

**Decided 2026-07-28.** A registered entry and a notecard pose in the same menu
may carry the same label. Dispatch matches on label text, so this has to be
resolved rather than left to chance.

**The registered entry wins.** The reasoning is asymmetry of control: a creator
can rename a pose in their own notecard, but the plugin is somebody else's
source code and often cannot be touched. The shadowed pose is not reachable
from that menu.

**A warning is mandatory.** Silent shadowing is the failure mode this rule
exists to prevent: a customer installs a plugin whose button happens to be named
like one of their poses, and a pose quietly stops working.

```
[QS]menu: "Lesen" in menu "Entspannen" is registered by [QS]myplugin and is
also a pose in the notecard. The registered entry wins and the pose is not
reachable here. Rename one of them.
```

**Emitted at registration, never at render.** This matters: rendering happens
every time somebody opens a menu, and a per-render owner-say multiplies across
every piece of furniture on the region. Registration happens once per script
lifetime and once per census, which bounds it to creator-triggered moments.

The warning goes out at the always-on verbosity level, not behind a debug flag.
It reports a real misconfiguration, not diagnostics.

**Creator control is the notecard itself.** There is no registration token in
the notecard, and none is needed. A creator who wants registered entries inside
a menu of their own simply declares that menu:

```
MENU Extras
POSE Kissen richten | fluff_pillow
```

A plugin registering under `Extras` then appears after `Kissen richten`, in a
menu the creator named and positioned. If nobody declares `Extras`, the
registration creates it.

---

## 5. Identity, dedupe and re-announce

The dedupe key is `owner`, that is `llGetScriptName()`. Two consequences, both
inherited from today's behaviour:

* A re-announce after a script reset or an inventory change **overwrites** the
  existing slot instead of appending a duplicate.
* Renamed copies of the same script coexist as separate registrants, which is
  what makes the paging stress test in `qs/examples/README.md` work.

Registrants announce on `state_entry` and re-announce on
`changed(CHANGED_INVENTORY)` and on the boot census (section 6).

---

## 6. Lifecycle and orphan reaping

A script deleted without unregistering would otherwise leave a dead button
behind. The existing mechanism covers it: the boot **census** wipes `qs:alive:*`
and asks everyone to re-announce. The same round clears the registry and rebuilds
it from the replies, so an entry with no living owner does not survive.

This also bounds the registration race noted in DESIGN.md open question 1c: the
window is from rez until the first census round, not indefinite. It is more
visible for a **top level** entry than for one inside `[OPTIONS]`, because that
is where someone looks first after rezzing.

---

## 7. Worked example

### The registrant

```lsl
// [QS]adjuster, state_entry
reg("[HELPER]",     "",          90401, FLAG_OWNER);
reg("[HELPER HUD]", "",          90402, FLAG_OWNER);
reg("[NEW]",        "Authoring", 90403, FLAG_OWNER);
reg("[SAVE]",       "Authoring", 90404, FLAG_OWNER);
reg("[DUMP]",       "Authoring", 90405, FLAG_OWNER);
```

Five lines, and they live in the adjuster rather than in `menu`.

### The notecard

Complete, unchanged by any of this:

```
SEAT Sitz

MENU Entspannen
POSE Lesen | read_sit
POSE Dösen | doze_sit
```

### What the seated user sees

With the adjuster in the prim:

```
Top:         [Entspannen >]  [HELPER]  [HELPER HUD]  [Authoring >]
Entspannen:  [Lesen]  [Dösen]
Authoring:   [NEW]  [SAVE]  [DUMP]
```

After `/5 cleanup`:

```
Top:         [Entspannen >]
Entspannen:  [Lesen]  [Dösen]
```

The `Authoring` menu is gone because it was never in the notecard. It existed
only while something registered a path through it. The notecard is untouched,
nothing is left behind, and the bytes leave with the script.

### A third-party plugin

```lsl
llMessageLinked(LINK_SET, 90212,
    "Kissen aufschütteln|90501|" + llGetScriptName() + "|0|Extras", "");
```

---

## 8. Open points

1. **Placement vocabulary.** Is a free-form path right, or should registrants
   pick from a small set of named anchors? Free form is proposed because it
   needs no new concept, but it lets a plugin author invent menus in someone
   else's furniture.
2. **Depth limit for auto-created paths.** Unbounded nesting from a registration
   is probably not wanted.
3. ~~Collision between a registered label and a notecard pose label.~~
   **Decided 2026-07-28**, see section 4: the registered entry wins and a
   warning is emitted at registration. Still open underneath it: whether the
   warning should also be recorded somewhere durable, so a creator who was not
   in-world when it fired can still find it. `boot`'s existing self-check report
   is the obvious host, at the cost of an LSD key.
4. **Top-level registration race**, see section 6 and DESIGN.md question 1c.
   Needs an in-world look before this is called done.
