string version = "0.27";

/*
 * [QS]seat - QuickySitter v2 occupancy engine
 *
 * Singleton despite the singular name: it manages every seat. It owns
 * WHO SITS WHERE. [QS]core owns WHAT GETS PLAYED.
 *
 * Responsibilities: sit targets, the occupancy table, the sit/stand
 * lifecycle, seat swapping, and driving the animations.
 *
 * DROP-IN REPLACEMENT. Together with core and menu this replaces the 2N
 * [QS]sitA / [QS]sitB instances. It reads the schema today's [QS]boot
 * already writes and speaks the existing 900xx wire, so the notecard,
 * the plugins and the HUD are untouched. See qs2/STATUS.md stage 1.
 *
 * ADDRESSING IS THE CHANNEL. In the v1 schema a seat IS a channel
 * integer: qs:p:<ch>:<i>, qs:cfg:<ch>, qs:sitter:<ch>. There are no item
 * names and no seat names, because without an ITEM token there is only
 * ever one piece of furniture. Grouping arrives in stage 2.
 *
 * SEAT COUNT COMES FROM LSD, not from counting scripts. v1 derives it by
 * probing the inventory for "[QS]sitA <n>" (sitA.lsl:285), which is the
 * one script-name probe in the codebase and cannot survive this rebuild.
 * Counting qs:sitter:<ch> keys gives the same answer from the notecard,
 * where it belongs. See DESIGN.md §7.2.
 *
 * IT DRIVES THE ANIMATIONS ITSELF. There is no per-seat animator script.
 * Measured in-world 2026-07-29 (DESIGN.md §3): the permission grant is
 * synchronous for an avatar already seated on the object, so one handler
 * can acquire and start every occupant in turn at 1.2 ms per seat. Eight
 * seats fit inside a 22 ms frame with room to spare, which is what keeps
 * SYNC couple poses in phase - tighter than N independent scripts, since
 * there is no scheduling boundary between the calls.
 *
 * run_time_permissions is a FALLBACK, not the mechanism. The synchronous
 * grant remains the design (measured, DESIGN.md §3), but it was measured
 * on avatars seated via sit targets; a single-prim arrival occupies no
 * target and its grant has been observed to miss the synchronous window.
 * Those starts are parked in PENDING and retried when the grant lands.
 * The event still cannot tell overlapping requests apart, which is why
 * it is only ever the retry path and never the primary one.
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */


integer QSS_OCCUPIED = 90410;
integer QSS_VACATED  = 90411;
integer QSS_TOUCH    = 90412;
integer QSS_SEATED   = 90413;
integer QSS_SWAP     = 90414;
integer QSS_NUDGE    = 90415;   // menu -> seat, live offset preview

integer QSC_APPLY   = 90421;
integer QSC_RESYNC  = 90423;

integer QS_ALIVE_CENSUS = 90079;   // boot wiped presence, re-stamp
integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

// Stock AVsitter numbers, emitted so stock plugins keep working
// (DESIGN.md §7.5).
integer AV_HELPERMOVED = 90057;   // HUD/helper -> here: absolute sit-target move
integer AV_NEWSITTER  = 90060;
integer AV_SITTERGONE = 90065;
integer AV_MENUTOUSER = 90005;
integer AV_SITTERSUPD = 90070;   // "sitter list updated", msg = slot, id = avatar

// SEATS strided 5: primLink, occupant, currentAnim, basePos, baseRot
// basePos/baseRot are what the running pose resolved to, kept so a live
// offset nudge has something to add to and so releasing the nudge
// dialog without saving can be undone by re-applying the pose.
// Index into SEATS/SEAT_STRIDE IS the channel number.
// occupant is "" when free (an LSL key defaults to "", never NULL_KEY).
list SEATS;
integer SEAT_STRIDE = 5;

// v2 FORK ONLY, stage 2 (DESIGN.md section 11). Strided 3: name,
// firstChannel, channelCount, read from qs:item:<idx>. boot writes one
// row even for a notecard with no ITEM line (unnamed, owning every
// channel), so the two shapes need no special case here.
list ITEMS;
integer ITEM_STRIDE = 3;

// Which item a seat belongs to, one entry per seat, derived from ITEMS.
// Kept flat beside SEATS rather than widening it: only the scoping paths
// ask, and every SEATS row is touched on the hot path.
list SEAT_ITEM;

// Per-seat gender from the notecard's SITTER directives, cfg field 16:
// 1 male, 0 female, -1 unassigned. Empty when the notecard declares
// none, and then regender is a no-op.
list GENDERS;

integer MTYPE;
integer SET;                       // cfg field 2; a prim pin only counts
                                   // when its SET matches this furniture

// DOOR PRIMS (DESIGN.md §10 for the mechanism, §11 for items). A prim
// carrying MORE THAN ONE seat is a door; one carrying exactly one is a
// classic sit target. Nothing configures this - it falls out of how
// resolve_bindings assigned the seats, so "#Couple" (whole item on one
// prim) and "#Couple-0" (one prim per seat) can sit in the same linkset
// and each behaves correctly.
//
// On a door the sit target is not a PLACE, it is a turnstile: it exists
// so the prim is sittable at all (measured: a prim with no target cannot
// be sat on), it is consumed by each arrival (measured: one llSitTarget
// call admits exactly one sitter), and it re-opens only on a CHANGED
// value, hence the alternating epsilon. Where an arrival LANDS is SL's
// click-relative placement, which is what picks the seat; where they
// finally SIT is move_occupant's job, as everywhere else.
//
// KNOWN, ACCEPTED FOR THE PROTOTYPE:
//   - between an arrival and the re-arm the prim admits nobody, so two
//     people sitting in the same instant lose one of them (they simply
//     do not sit; no event fires anywhere)
//   - CLICK_ACTION_SIT takes the left click on a door prim, so the menu
//     cannot be opened by clicking it (the MTYPE/ETYPE question, still
//     undecided)
//   - per-seat camera is impossible on a door, llSetLinkCamera being
//     prim-bound
integer armcount;

// Animation starts whose permission grant did not come back
// synchronously, strided 3: avatar, seat, anim. Retried from
// run_time_permissions when the grant lands. Rows for somebody who
// stood up in the meantime die on the occupant check there.
list PENDING;

// Same, for the stop half of a pose change, strided 2: avatar, anim.
list PENDING_STOP;

// THE FRAME A POSE POSITION IS MEASURED IN, filled by frame_of. Out-
// params rather than a return value: an LSL function returns one thing
// and both halves are always wanted together.
vector   FRAME_POS;
rotation FRAME_ROT;

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// ---------------------------------------------------------------- lookup

integer seat_of_link(integer link)
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    while (i < n)
    {
        if (llList2Integer(SEATS, i) == link) return i / SEAT_STRIDE;
        i += SEAT_STRIDE;
    }
    return -1;
}

integer seat_of_avatar(key av)
{
    integer i = 1;
    integer n = llGetListLength(SEATS);
    while (i < n)
    {
        if (llList2String(SEATS, i) == (string)av) return i / SEAT_STRIDE;
        i += SEAT_STRIDE;
    }
    return -1;
}

// ------------------------------------------------------------- LSD load

load_from_lsd()
{
    SEATS = [];

    string v = llLinksetDataRead("qs:cfg:verbose");
    if (v != "") verbose = (integer)v;

    // Field 0 of the packed per-channel config. Only the fields this
    // script actually acts on are unpacked; core and menu unpack their
    // own. Same string for every channel, boot writes it once at EOF.
    list cfg = llParseStringKeepNulls(llLinksetDataRead("qs:cfg:0"), ["\n"], []);
    MTYPE = (integer)llList2String(cfg, 0);
    SET     = (integer)llList2String(cfg, 2);
    GENDERS = llCSV2List(llList2String(cfg, 16));

    // Item table, then the seat->item column derived from it.
    ITEMS = [];
    SEAT_ITEM = [];
    integer it = 0;
    string irow = llLinksetDataRead("qs:item:0");
    while (irow != "")
    {
        list f = llParseStringKeepNulls(irow, ["|"], []);
        ITEMS += [llList2String(f, 0), (integer)llList2String(f, 1),
                  (integer)llList2String(f, 2)];
        integer k = 0;
        while (k < (integer)llList2String(f, 2)) { SEAT_ITEM += it; ++k; }
        ++it;
        irow = llLinksetDataRead("qs:item:" + (string)it);
    }

    // Count seats by walking qs:sitter:<ch> until it runs out.
    integer ch = 0;
    while (llLinksetDataRead("qs:sitter:" + (string)ch) != "")
    {
        SEATS += [0, "", "", ZERO_VECTOR, ZERO_VECTOR];
        ++ch;
    }
    if (ch == 0) Out(0, "no qs:sitter:0 - has [QS]boot run?");
}

// -------------------------------------------------------- prim binding

// A FAITHFUL PORT OF v1.s sittargets() (sitA.lsl:324), because which prim
// a seat is bound to decides which frame its pose positions are measured
// in. Get the binding wrong and every pose on that seat is displaced,
// which is exactly how it showed up in-world: everything worked, the
// positions were simply not the notecard.s.
//
// The first attempt here reinvented the rules and got three of them
// wrong, all in the direction of rejecting pins that v1 accepts:
//
//   1. v1 takes the substring AFTER the first "#", and llSubStringIndex
//      returns -1 when there is none, so +1 lands on 0 and the WHOLE
//      description is used. A bare "1-0" is a pin. This required a
//      leading "#" and read "1-0" as an unpinned prim.
//   2. v1 only honours a pin whose SET matches this furniture.s. This
//      ignored the SET field and pinned prims belonging to another set.
//   3. v1 fills unpinned prims into the first still-empty slot DURING
//      the same pass, so a later pin can overwrite a slot an earlier
//      unpinned prim took. This collected all free prims first and
//      distributed them afterwards, which is a different result whenever
//      pins and unpinned prims are interleaved.
//
// Kept structurally close to the original so the next person can diff it
// rather than trust this comment.
integer is_integer(string data)
{
    if (data == "") return FALSE;
    return (string)((integer)("1" + data)) == "1" + data;
}

// v2 FORK ONLY, stage 2 (DESIGN.md §11). THE NAME IS THE ADDRESS: a prim
// described "#Sofa-1" is seat 1 OF THE SOFA. The number before the "-"
// keeps its legacy meaning when it IS a number, so every existing
// #SET-slot build parses exactly as before.
//
// Returns the GLOBAL channel for (itemName, localSlot), or -1 when the
// name matches no item - which is a warning, never a silent free prim.
// A description naming a misspelled item must not quietly become an
// unrelated seat.
// Do two seats belong to the same item? TRUE when the notecard declares
// no items, so every scoped path degrades to the single-furniture
// behaviour it had before stage 2. Safe for a == b, which matters
// because LSL has no short-circuit and callers pair it with an
// inequality test in the same condition.
integer same_item(integer a, integer b)
{
    if (llGetListLength(SEAT_ITEM) == 0) return TRUE;
    return llList2Integer(SEAT_ITEM, a) == llList2Integer(SEAT_ITEM, b);
}

// Did the notecard declare items? boot writes qs:item:0 either way, but
// leaves the name EMPTY for a card with no ITEM line. That emptiness is
// the whole opt-in test.
integer items_declared()
{
    if (llGetListLength(ITEMS) == 0) return FALSE;
    return llList2String(ITEMS, 0) != "";
}

// v1 measures every pose against the prim the SITTER SCRIPT lives in -
// one frame for the whole linkset. That is right for one piece of
// furniture and wrong for several: move the chair prim and its poses
// stay behind, because they were never anchored to it.
//
// With items declared, each seat is measured against ITS OWN prim, so an
// item is a self-contained thing a builder can move, rotate and relink
// without touching a single coordinate. Personal offsets need no
// separate handling: they are added to the pose position before this
// transform, so they live in the same space and travel with it.
//
// WHY IT IS CONDITIONAL. Switching unconditionally would displace every
// pose in every notecard ever authored - precisely the defect hunted
// down to five decimal places in seat 0.18. No existing card has an ITEM
// line, so writing one is the author declaring v2 semantics.
frame_of(integer seat)
{
    FRAME_POS = ZERO_VECTOR;
    FRAME_ROT = ZERO_ROTATION;

    integer link = llGetLinkNumber();          // v1: the script's prim
    if (items_declared())
    {
        link = llList2Integer(SEATS, seat * SEAT_STRIDE);
        if (link <= 0) return;
    }
    if (link <= 1) return;                     // root frame is identity

    list p = llGetLinkPrimitiveParams(link, [PRIM_POS_LOCAL, PRIM_ROT_LOCAL]);
    FRAME_POS = llList2Vector(p, 0);
    FRAME_ROT = llList2Rot(p, 1);
}

integer item_index(string itemName)
{
    integer idx = 0;
    while (idx < llGetListLength(ITEMS) / ITEM_STRIDE)
    {
        if (llList2String(ITEMS, idx * ITEM_STRIDE) == itemName) return idx;
        ++idx;
    }
    return -1;
}

integer channel_of(string itemName, integer localSlot)
{
    integer idx = 0;
    while (idx < llGetListLength(ITEMS) / ITEM_STRIDE)
    {
        if (llList2String(ITEMS, idx * ITEM_STRIDE) == itemName)
        {
            integer first = llList2Integer(ITEMS, idx * ITEM_STRIDE + 1);
            integer count = llList2Integer(ITEMS, idx * ITEM_STRIDE + 2);
            if (localSlot < 0 || localSlot >= count) return -1;
            return first + localSlot;
        }
        ++idx;
    }
    return -1;
}

resolve_bindings()
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    // Prim count WITHOUT seated avatars. llGetNumberOfPrims counts them.
    integer prims = llGetObjectPrimCount(llGetKey());

    if (seats == 1)
    {
        // v1 uses the link the script itself sits in. For a singleton
        // that is wherever the base set was dropped, which on
        // single-seat furniture is the seat prim.
        SEATS = llListReplaceList(SEATS, [llGetLinkNumber()], 0, 0);
        return;
    }

    list slots;                        // link per seat, 0 = still unfilled
    integer i = 0;
    while (i < seats) { slots += 0; ++i; }

    i = 1;
    while (i <= prims)
    {
        integer next = llListFindList(slots, [0]);
        string desc = llList2String(llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0);
        desc = llGetSubString(desc, llSubStringIndex(desc, "#") + 1, 99999);
        if (desc != "-1")
        {
            list data = llParseStringKeepNulls(desc, ["-"], []);

            // "#Sofa" - NO SLOT: the whole item lives on this prim, and
            // every one of its seats binds here. That makes the prim a
            // door (is_door counts >1 seat), so arrivals are placed by
            // landing position within the item.
            //
            // This was specified in DESIGN section 11 and then not
            // built, so a description carrying only a name fell through
            // BOTH branches below and was treated as an unpinned prim -
            // sitting on the chair handed out a sofa seat, in link
            // order. An empty description still means unpinned, which is
            // why the emptiness test comes first.
            if (llGetListLength(data) == 1 && desc != ""
                && !is_integer(desc))
            {
                integer ii = item_index(desc);
                if (ii == -1)
                {
                    Out(0, "prim " + (string)i + " is described \"" + desc
                        + "\" but no item has that name"
                        + " - prim left unassigned.");
                }
                else
                {
                    integer ifirst = llList2Integer(ITEMS, ii * ITEM_STRIDE + 1);
                    integer icount = llList2Integer(ITEMS, ii * ITEM_STRIDE + 2);
                    integer k = 0;
                    while (k < icount)
                    {
                        integer gch = ifirst + k;
                        if (gch < seats)
                            slots = llListReplaceList(slots, [i], gch, gch);
                        ++k;
                    }
                    Out(2, "prim " + (string)i + " carries item \"" + desc
                        + "\", seats " + (string)ifirst + ".."
                        + (string)(ifirst + icount - 1));
                }
            }
            // "#Sofa-1" - NAME AND SLOT: one specific seat on this prim.
            // Checked before the legacy branch, which requires BOTH
            // fields to be integers, so a named item can never be
            // mistaken for one.
            else if (llGetListLength(data) == 2
                && !is_integer(llList2String(data, 0))
                && is_integer(llList2String(data, 1)))
            {
                integer gch = channel_of(llList2String(data, 0),
                    (integer)llList2String(data, 1));
                if (gch == -1)
                {
                    Out(0, "prim " + (string)i + " is described \""
                        + desc + "\" but no item is named \""
                        + llList2String(data, 0)
                        + "\" - prim left unassigned.");
                }
                else if (gch < seats)
                {
                    slots = llListReplaceList(slots, [i], gch, gch);
                }
            }
            else if (llGetListLength(data) == 2
                && is_integer(llList2String(data, 0))
                && is_integer(llList2String(data, 1)))
            {
                if (llList2Integer(data, 0) == SET)
                {
                    integer slot = llList2Integer(data, 1);
                    if (slot >= 0 && slot < seats)
                        slots = llListReplaceList(slots, [i], slot, slot);
                }
            }
            else if (next != -1)
            {
                slots = llListReplaceList(slots, [i], next, next);
            }
        }
        ++i;
    }

    i = 0;
    while (i < seats)
    {
        SEATS = llListReplaceList(SEATS, [llList2Integer(slots, i)],
            i * SEAT_STRIDE, i * SEAT_STRIDE);
        ++i;
    }
}

// ------------------------------------------------------------- gender
//
// A SITTER directive can declare a seat male, female or unassigned, and
// boot collects those into cfg field 16. Without this a male avatar
// simply took whichever seat came first and landed on the female pose,
// which is what the notecard was written to prevent.
//
// v1 does this from sitA (sitA.lsl:1310) as part of claiming a sitter.
// It cannot be lifted verbatim: there, each sitA owns one prim and
// decides whether to adopt the arrival, so choosing a seat is a matter
// of which instance says yes. Here the arrival is already physically on
// a prim, so preferring a different seat means moving the SEAT, not the
// avatar - the prim binding is swapped with a free seat that wants this
// gender. Nobody is unseated and the sit target is not touched.

// OBJECT_BODY_SHAPE_TYPE is 0.0 female, 1.0 male, -1.0 for non-avatars.
// v1 truncates it with llList2Integer and this matches that deliberately:
// a drop-in has to assign the same seats as the script it replaces, even
// where a fresh implementation would round instead.
integer gender_of(key av)
{
    return llList2Integer(llGetObjectDetails(av, [OBJECT_BODY_SHAPE_TYPE]), 0);
}

swap_prims(integer a, integer b)
{
    integer ra = a * SEAT_STRIDE;
    integer rb = b * SEAT_STRIDE;
    integer la = llList2Integer(SEATS, ra);
    integer lb = llList2Integer(SEATS, rb);
    SEATS = llListReplaceList(SEATS, [lb], ra, ra);
    SEATS = llListReplaceList(SEATS, [la], rb, rb);
}

// Returns the seat this arrival should actually occupy, having swapped
// the prim bindings if that differs from the one they sat on.
integer regender(integer seat, key av)
{
    if (llGetListLength(GENDERS) == 0) return seat;
    integer want = llList2Integer(GENDERS, seat);
    if (want == -1) return seat;              // seat takes anybody
    integer g = gender_of(av);
    if (want == g) return seat;

    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer i = 0;
    while (i < seats)
    {
        // WITHIN THE ITEM ONLY (stage 2). Without this scope a male
        // arriving on the sofa's female seat could be "helpfully" moved
        // onto the armchair across the room, because the armchair's seat
        // also wants a male and is also free. same_item is true for every
        // pair when the notecard declares no items, so single-furniture
        // behaviour is unchanged.
        if (i != seat && same_item(i, seat))
        {
            // Only ever trade with a seat that is FREE, so an occupant is
            // never displaced to make room for somebody arriving later.
            if (llList2String(SEATS, i * SEAT_STRIDE + 1) == "")
            {
                if (llList2Integer(GENDERS, i) == g)
                {
                    swap_prims(seat, i);
                    Out(2, "gender: arrival is " + (string)g
                        + ", seat " + (string)seat + " wants " + (string)want
                        + " - moved to seat " + (string)i);
                    return i;
                }
            }
        }
        ++i;
    }
    return seat;                              // no better seat free
}

// SL allows one sit target per prim, so a seat without a prim cannot be
// sat on. Same condition as v1's "not enough prims for required
// SitTargets" (sitA.lsl:33).
// A DOOR IS PER PRIM, not per object. A prim that carries several seats
// needs its own, and a linkset can hold one such prim per item.
//
// The alternating epsilon is the mechanism, measured: llSitTarget with
// the value it already holds is a no-op and admits nobody, so the door
// only re-opens when the vector actually changes.
//
// llLinkSitTarget on link 0 is not addressable, which is why the lone
// prim case still goes through llSitTarget: an unoccupied single prim
// reports link 0, and it becomes link 1 only once somebody sits.
arm_door(integer link)
{
    ++armcount;
    vector t = <0.0, 0.0, 0.1 + 0.0001 * (float)(armcount % 2)>;
    if (link <= 1 && llGetObjectPrimCount(llGetKey()) == 1)
        llSitTarget(t, ZERO_ROTATION);
    else
        llLinkSitTarget(link, t, ZERO_ROTATION);
}

// Is this prim a multi-seat door? TRUE when more than one seat is bound
// to it. Derived rather than flagged, so a prim gains or loses door
// status purely by how resolve_bindings assigned the seats.
integer is_door(integer link)
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer i = 0;
    integer count = 0;
    while (i < seats)
    {
        if (llList2Integer(SEATS, i * SEAT_STRIDE) == link) ++count;
        ++i;
    }
    return count > 1;
}

// Where a seat "is", for matching a landing position against the layout:
// what is currently playing there, or the seat's first playable pose
// before anything has played. Read from the same qs:p rows core plays
// from, so the picker and the engine cannot disagree about geometry.
vector seat_home(integer ch)
{
    vector bp = llList2Vector(SEATS, ch * SEAT_STRIDE + 3);
    if (bp != ZERO_VECTOR) return bp;
    integer n = (integer)llLinksetDataRead("qs:cfg:slots:" + (string)ch);
    integer i = 0;
    while (i < n)
    {
        list e = llParseStringKeepNulls(
            llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i), ["|"], []);
        string t = llList2String(e, 1);
        if (t == "P" || t == "S") return (vector)llList2String(e, 3);
        ++i;
    }
    return ZERO_VECTOR;
}

// Nearest FREE seat to where SL dropped the arrival. Z is weighted down
// (qs2/test/sitpick.lsl): landing heights hug the prim surface and say
// little about intent, but a bunk bed's two seats differ only in Z, so
// it cannot be discarded outright either.
// SCOPED TO ONE PRIM, which is what makes items work: the arrival sat
// on a specific prim, that prim belongs to one item, and only that
// item's seats are candidates. Resolution reads prim -> item -> seat
// instead of searching every seat in the linkset.
integer pick_seat(integer link, vector p)
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer best = -1;
    float bestd = -1.0;
    integer i = 0;
    while (i < seats)
    {
        if (llList2Integer(SEATS, i * SEAT_STRIDE) == link
            && llList2String(SEATS, i * SEAT_STRIDE + 1) == "")
        {
            vector d = p - seat_home(i);
            d.z = d.z * 0.3;
            float dist = llVecMag(d);
            if (bestd < 0.0 || dist < bestd) { bestd = dist; best = i; }
        }
        ++i;
    }
    return best;
}

place_sittargets()
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    integer missing = 0;
    list armed;                        // door prims already handled

    while (i < n)
    {
        integer link = llList2Integer(SEATS, i);
        if (link > 0)
        {
            if (is_door(link))
            {
                // Several seats share this prim: it gets ONE door, and
                // its click action must seat, because that is what
                // carries the click point into the landing position
                // (measured; with the default action, deliberate
                // end-clicks failed to seat at all).
                if (llListFindList(armed, [link]) == -1)
                {
                    armed += link;
                    llSetLinkPrimitiveParamsFast(link,
                        [PRIM_CLICK_ACTION, CLICK_ACTION_SIT]);
                    arm_door(link);
                }
            }
            else
            {
                llLinkSitTarget(link, <0.0, 0.0, 0.1>, ZERO_ROTATION);
            }
        }
        else ++missing;
        i += SEAT_STRIDE;
    }

    // Only seats with NO prim at all are a problem now: a shortage of
    // prims is a legitimate build, since one prim can carry an item.
    if (missing)
        llDialog(llGetOwner(), "\n" + (string)missing + " seat(s) have no"
            + " prim.\nGive each item a prim named after it (#Couple),"
            + "\nor one prim per seat (#Couple-0).",
            ["OK"], 23658);
}

// v1's formula, restored after measuring what removing it actually did.
// The -0.4 on Z and the 0.05 nudge along the target's up axis are from
// sitA.lsl:460.
//
// IT WAS TAKEN OUT ON A WRONG READING and put back on evidence. The
// reasoning for removing it was that the sit target is a throwaway,
// since move_occupant overwrites the avatar's position on every pose
// apply anyway. Measured side by side against v1 on the same furniture,
// same avatar, same pose (qs2/test/zprobe.lsl):
//
//   v1   avatar Z 0.259   target Z -0.091
//   v2   avatar Z 0.259   target Z  0.259
//
// The AVATAR LINK POSITIONS ARE IDENTICAL. move_occupant's arithmetic
// was never wrong. But SL derives the seated avatar's rendered offset
// from the SIT TARGET, not from the link position, so the target still
// governs what anyone sees. In v1 the two agree - -0.091 plus the ~0.35
// SL adds lands exactly on 0.259 - and removing the compensation broke
// that agreement while leaving every reported number looking correct.
//
// Which is why it was invisible to five rounds of reading code: nothing
// in either engine's own state disagreed.
set_seat_target(integer seat, vector pos, rotation rot)
{
    integer link = llList2Integer(SEATS, seat * SEAT_STRIDE);
    if (link <= 0) return;

    // On a door prim the target belongs to the DOOR and nothing else may
    // write it: letting a pose apply land here would re-aim the door at
    // that pose, which is exactly the value the next arrival must NOT
    // inherit. Occupants of a door prim are placed by move_occupant
    // alone, which is where they are placed anyway.
    if (is_door(link)) return;

    // v1 suppresses the target entirely on an excluded prim
    // (sitA.lsl:458), so a prim marked "never seat anyone here" cannot be
    // sat on even if the binding somehow handed it out.
    string desc = llList2String(llGetLinkPrimitiveParams(link, [PRIM_DESC]), 0);
    desc = llGetSubString(desc, llSubStringIndex(desc, "#") + 1, 99999);
    if (desc == "-1") return;

    // SAME FRAME QUESTION AS move_occupant, and v1 answers it here with
    // an explicit conversion (sitA.lsl:434). A sit target is always
    // written in the TARGET prim's own local frame, so the pose has to
    // be carried from whatever frame it was authored in into that one.
    //
    // With items declared those two ARE the same prim, and the whole
    // conversion collapses to nothing - which is the point of anchoring
    // a pose to its item rather than to the script.
    vector   tp = pos;
    rotation tr = rot;

    frame_of(seat);
    vector   lp = FRAME_POS;
    rotation lr = FRAME_ROT;

    tp = lp + pos * lr;                           // -> root frame
    tr = rot * lr;
    if (link > 1)
    {
        list p = llGetLinkPrimitiveParams(link,
            [PRIM_POS_LOCAL, PRIM_ROT_LOCAL]);
        rotation tlr = llList2Rot(p, 1);
        tp = (tp - llList2Vector(p, 0)) / tlr;    // -> target prim frame
        tr = tr / tlr;
    }

    llLinkSitTarget(link, tp - <0.0, 0.0, 0.4> + llRot2Up(tr) * 0.05, tr);
}

// A SEATED AVATAR IS ITS OWN LINK. Seated agents occupy link numbers
// above the prim count, and moving one means setting prim params on that
// link. The sit target only says where the NEXT sit lands, so setting it
// alone leaves whoever is already sitting exactly where they were - which
// is why the HUD's adjust arrows arrived (verified on the wire: 90057
// reached this script) and still moved nobody.
//
// v1 does this from sit_using_prim_params (sitA.lsl:622) on EVERY
// position change, pose applies included, not just on the helper path.
integer av_link(key av)
{
    integer n = llGetNumberOfPrims();
    while (llGetAgentSize(llGetLinkKey(n)) != ZERO_VECTOR)
    {
        if (llGetLinkKey(n) == av) return n;
        --n;
    }
    return 0;
}

// rotEuler is in degrees, matching the notecard and the whole 900xx wire.
move_occupant(integer seat, vector pos, vector rotEuler)
{
    key av = (key)llList2String(SEATS, seat * SEAT_STRIDE + 1);
    if (av == "") return;
    integer link = av_link(av);
    if (link == 0)
    {
        // Not silent. If this ever misses, the avatar stays wherever the
        // sit target dropped them, which is 0.4 m BELOW the pose - the
        // sit target carries that offset by AVsitter convention and the
        // prim-params move is what corrects it. "Every pose sits too
        // low" is precisely what that looks like.
        Out(0, "seat " + (string)seat + ": avatar has no link yet, not moved.");
        return;
    }
    Out(2, "move seat " + (string)seat + " link " + (string)link
        + " to " + (string)pos + " / " + (string)rotEuler);

    // THE FRAME IS THIS SCRIPT'S PRIM, not the seat's, and this had it
    // the other way round. An AVpos position is measured relative to the
    // prim the SITTER SCRIPT lives in, the same one for every seat.
    //
    // The proof is in v1 rather than in any document: set_sittarget
    // (sitA.lsl:434) converts the pose from llGetLocalPos/Rot's frame
    // into the TARGET prim's local frame before writing the sit target.
    // That conversion would be pointless if the pose were already
    // expressed in the target prim's frame.
    //
    // Reading the seat prim here instead displaced every seat by that
    // prim's own local position, constant across all its poses, zero for
    // whichever seat happens to sit on the script's prim. That last
    // property is why it hid: the measurement that finally caught the
    // sit target was taken on prim 1, where the two frames coincide.
    //
    // ...UNLESS THE NOTECARD DECLARES ITEMS, in which case the frame is
    // the seat's own prim. See frame_prim: ITEM is the opt-in, because
    // no existing card has one.
    vector   lp;
    rotation lr;
    frame_of(seat);
    lp = FRAME_POS;
    lr = FRAME_ROT;

    // The 0.002 degree nudge is v1's and it is load-bearing: an update
    // that resolves to the identical rotation is dropped, so a repeated
    // press on one axis would stop having any effect.
    llSetLinkPrimitiveParamsFast(link,
        [PRIM_ROT_LOCAL, llEuler2Rot((rotEuler + <0.0, 0.0, 0.002>) * DEG_TO_RAD) * lr,
         PRIM_POS_LOCAL, pos * lr + lp]);
}

// ------------------------------------------------------------ animation

// Permission is taken per call rather than held, because a script holds
// it for exactly one avatar at a time (llGetPermissionsKey is single
// valued). Acquiring at sit time would be pointless: the next seat
// overwrites it immediately. Measured cost 1.2 ms.
//
// Losing the permission does NOT stop a running animation, which is the
// property this whole design rests on.
integer seat_start(integer seat, string anim)
{
    key av = (key)llList2String(SEATS, seat * SEAT_STRIDE + 1);
    if (av == "") return FALSE;
    llRequestPermissions(av, PERMISSION_TRIGGER_ANIMATION);

    // THE KEY CHECK IS THE WHOLE FUNCTION. Without it, a grant that is
    // not synchronous leaves llGetPermissions() reporting the PREVIOUS
    // holder's mask, the test passes, and llStartAnimation animates the
    // wrong avatar: sitter 1 keeps playing, sitter 2 gets nothing. That
    // is not hypothetical - it is the permtest keyMatches bug, shipped.
    //
    // The synchronous grant was measured on avatars seated via sit
    // targets. A single-prim arrival occupies NO target, and whether the
    // auto-grant is synchronous for them had never been measured, so the
    // miss is parked and retried when the grant lands.
    if (llGetPermissionsKey() == av)
    {
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        {
            if (anim != "") llStartAnimation(anim);
            Out(2, "started " + anim + " on " + llKey2Name(av));
            return TRUE;
        }
    }
    Out(1, "grant for " + llKey2Name(av) + " not synchronous - parked.");
    PENDING += [(string)av, seat, anim];
    return FALSE;
}

// NEVER call this for an avatar who has stood up. Auto-grant only
// applies while the avatar is sitting ON the object; off it,
// llRequestPermissions pops a DIALOG at them. Standing up already
// revoked the permission and stopped the animation, so there is nothing
// to do on that path anyway.
//
// The guard is here rather than at the call sites because every caller
// would otherwise have to remember it, and the failure is a permission
// dialog in a customer's face.
seat_stop(integer seat, string anim)
{
    if (anim == "") return;
    key av = (key)llList2String(SEATS, seat * SEAT_STRIDE + 1);
    if (av == "") return;

    // Stop only somebody who is STILL SEATED, or the request dialog pops
    // for a standing avatar. Checked via the agent links rather than
    // llAvatarOnLinkSitTarget, which reports one avatar per prim and so
    // lies about arrivals 2+ in single-prim mode.
    if (av_link(av) == 0) return;      // already gone

    llRequestPermissions(av, PERMISSION_TRIGGER_ANIMATION);
    // SAME HOLDER CHECK AS seat_start, for the same reason: a mask-only
    // test passes on the PREVIOUS holder.s grant, and the old animation
    // then stops on the wrong avatar - a no-op for them, while whoever
    // should have stopped keeps playing their old pose OVER the new one.
    // A couple switch then looks like it half-worked: moved, new anim
    // started, old anim still winning on one of the two.
    if (llGetPermissionsKey() == av)
    {
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        {
            llStopAnimation(anim);
            Out(2, "stopped " + anim + " on " + llKey2Name(av));
            return;
        }
    }
    Out(1, "stop of " + anim + " for " + llKey2Name(av) + " parked.");
    PENDING_STOP += [(string)av, anim];
}

// ---------------------------------------------------------- lifecycle

seat_taken(integer seat, key av)
{
    SEATS = llListReplaceList(SEATS, [(string)av],
        seat * SEAT_STRIDE + 1, seat * SEAT_STRIDE + 1);
    llLinksetDataWrite("qs:occ:" + (string)seat, (string)av);

    // core can be told straight away: permission is taken at animation
    // time, so there is no grant to wait for.
    llMessageLinked(LINK_SET, QSS_OCCUPIED, (string)seat, av);
    llMessageLinked(LINK_SET, AV_NEWSITTER, (string)seat, av);
    // 90070 is what both HUD scripts build their own sitter mirror from
    // (hudproxy maintains it on 90060/90065/90070/90045; hudadmin looks
    // the avatar up in that list before attaching). v1 sends it from
    // sitA once the permission grant lands; here there is no grant to
    // wait for, so it goes out with the rest.
    //
    // Omitting it is why the HUD would not attach: hudadmin found the
    // avatar nowhere in SITTERS.
    llMessageLinked(LINK_SET, AV_SITTERSUPD, (string)seat, av);
    llMessageLinked(LINK_SET, QSS_SEATED, (string)seat, av);
}

seat_freed(integer seat, key was)
{
    // No stop call here. This runs because the avatar has ALREADY left
    // the sit target, so the permission and the animation are both gone,
    // and asking for permission again would put a dialog in front of
    // somebody who just stood up.
    SEATS = llListReplaceList(SEATS, [""], seat * SEAT_STRIDE + 1, seat * SEAT_STRIDE + 1);
    SEATS = llListReplaceList(SEATS, [""], seat * SEAT_STRIDE + 2, seat * SEAT_STRIDE + 2);
    llLinksetDataDelete("qs:occ:" + (string)seat);
    // qs:cur deliberately SURVIVES the stand-up. In v1 a seat's CURRENT
    // pose persists until the whole furniture empties, which is what
    // puts a brief stand-up back into the couple pose on re-sit. core
    // clears it on the last vacancy (QSS_VACATED handler).
    llMessageLinked(LINK_SET, QSS_VACATED, (string)seat, was);
    llMessageLinked(LINK_SET, AV_SITTERGONE, (string)seat, was);
}

// Which door prim did this landing position come from? The nearest one,
// measured against the prim's own local position.
//
// It cannot be llAvatarOnLinkSitTarget: that reports ONE avatar per
// prim, so from the second occupant of a door onwards it says nothing.
// Distance works for any number of them, because SL drops an arrival
// click-relative to the prim they clicked (measured, DESIGN section 10).
//
// Returns 0 when the build has no door prims at all.
integer nearest_door(vector p)
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer best = 0;
    float bestd = -1.0;
    list seen;
    integer i = 0;
    while (i < seats)
    {
        integer link = llList2Integer(SEATS, i * SEAT_STRIDE);
        if (link > 0 && llListFindList(seen, [link]) == -1)
        {
            seen += link;
            if (is_door(link))
            {
                vector lp = ZERO_VECTOR;
                if (link > 1) lp = llList2Vector(
                    llGetLinkPrimitiveParams(link, [PRIM_POS_LOCAL]), 0);
                float d = llVecMag(p - lp);
                if (bestd < 0.0 || d < bestd) { bestd = d; best = link; }
            }
        }
        ++i;
    }
    return best;
}

// ONE PASS, BOTH BUILD SHAPES, because a linkset may mix them: an item
// living on a single prim next to another with a prim per seat.
//
// STILL SELF-HEALING, which was the stated worry about leaving the
// per-prim lookup behind: agent links are re-derivable truth, walked in
// full on every scan, so a missed CHANGED_LINK is repaired by the next
// one instead of desynchronising the table forever. Only the seat
// CHOICE for a door arrival is genuinely new, and it reads the landing
// position SL computed from the click.
rescan_occupancy()
{
    // Departures first, so a stand-and-resit in one event frees the seat
    // before the arrival pass tries to pick one.
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer s = 0;
    while (s < seats)
    {
        string occ = llList2String(SEATS, s * SEAT_STRIDE + 1);
        if (occ != "")
        {
            if (av_link((key)occ) == 0) seat_freed(s, (key)occ);
        }
        ++s;
    }

    // Classic seats: the sit target names its occupant, which re-derives
    // the truth on every scan instead of accumulating it.
    s = 0;
    while (s < seats)
    {
        integer clink = llList2Integer(SEATS, s * SEAT_STRIDE);
        if (clink > 0)
        {
            if (!is_door(clink))
            {
                key now = llAvatarOnLinkSitTarget(clink);
                if (now == NULL_KEY) now = "";
                string before = llList2String(SEATS, s * SEAT_STRIDE + 1);
                if ((string)now != before)
                {
                    if (before != "") seat_freed(s, (key)before);
                    // regender may hand back a different seat, having
                    // swapped the prim bindings. The scan stays correct
                    // either way: the seat it moved to now points at the
                    // arrival's prim and has been recorded, so that row
                    // reads unchanged; the seat they came from points at
                    // a free prim and reads empty, which it is.
                    if (now != "") seat_taken(regender(s, now), now);
                }
            }
        }
        ++s;
    }

    // Arrivals: any agent link the table does not know yet.
    integer n = llGetNumberOfPrims();
    integer l = 2;
    while (l <= n)
    {
        key av = llGetLinkKey(l);
        if (llGetAgentSize(av) != ZERO_VECTOR)
        {
            if (seat_of_avatar(av) == -1)
            {
                vector p = llList2Vector(
                    llGetLinkPrimitiveParams(l, [PRIM_POS_LOCAL]), 0);

                // WHICH DOOR DID THEY COME THROUGH? That prim is the
                // item, and only its seats are candidates - resolution
                // reads prim, then item, then seat. A zero means the
                // build has no doors and the classic pass above already
                // owns this avatar.
                integer door = nearest_door(p);
                integer pick = -1;
                if (door) pick = pick_seat(door, p);
                if (door == 0)
                {
                    // Nothing to do; the classic scan handles them.
                }
                else if (pick == -1)
                {
                    // Every seat of THIS item is taken. v1 cannot get
                    // here - the sim refuses the sit when all targets
                    // are occupied - so there is no behaviour to copy,
                    // and leaving them seated but unanimated on top of
                    // somebody would be worse than the eject.
                    Out(0, "no free seat on prim " + (string)door
                        + " for " + llKey2Name(av) + ", unsitting.");
                    llUnSit(av);
                }
                else
                {
                    Out(2, "landed at " + (string)p + " on prim "
                        + (string)door + " -> seat " + (string)pick);
                    seat_taken(regender(pick, av), av);
                }
                // The door is consumed by this arrival either way, so it
                // is re-armed even after an eject - otherwise a rejected
                // sit would lock the prim for everybody after them.
                if (door) arm_door(door);
            }
        }
        ++l;
    }
}

// A row swap plus new sit targets. In v1 this was ~80 lines of protocol
// between two independent script instances (90030/90031).
// SWAPPING ACROSS ITEMS IS ONLY POSSIBLE ON DOOR PRIMS, and the reason
// is worth stating because it looks like an arbitrary restriction.
//
// A swap exchanges the OCCUPANT column and nothing physical: SL still
// believes each avatar sits where they sat, and move_occupant then
// places them at their new seat's position, in that seat's frame. For a
// door prim that is the whole story, because occupancy there is tracked.
//
// A classic seat RE-DERIVES its occupant from llAvatarOnLinkSitTarget on
// every scan. That self-healing property is the reason a missed event
// cannot desynchronise the table - and it also means the sit target,
// which still names the original sitter, would revert the swap on the
// next CHANGED_LINK. Overriding it would trade a permanent guarantee for
// one feature, which is not a trade worth making.
//
// Within one item both seats share a prim by construction, so the
// ordinary [SWAP] is unaffected either way.
integer swap_possible(integer a, integer b)
{
    if (same_item(a, b)) return TRUE;
    integer pa = llList2Integer(SEATS, a * SEAT_STRIDE);
    integer pb = llList2Integer(SEATS, b * SEAT_STRIDE);
    if (is_door(pa) && is_door(pb)) return TRUE;
    Out(0, "cross-item swap needs both items on their own prim"
        + " (a description like \"#Sofa\" rather than \"#Sofa-0\").");
    return FALSE;
}

swap_seats(integer a, integer b)
{
    if (a < 0 || b < 0) return;
    if (a == b) return;
    if (!swap_possible(a, b)) return;
    integer ra = a * SEAT_STRIDE;
    integer rb = b * SEAT_STRIDE;
    string occA = llList2String(SEATS, ra + 1);
    string occB = llList2String(SEATS, rb + 1);

    SEATS = llListReplaceList(SEATS, [occB], ra + 1, ra + 1);
    SEATS = llListReplaceList(SEATS, [occA], rb + 1, rb + 1);

    if (occB != "") llLinksetDataWrite("qs:occ:" + (string)a, occB);
    else            llLinksetDataDelete("qs:occ:" + (string)a);
    if (occA != "") llLinksetDataWrite("qs:occ:" + (string)b, occA);
    else            llLinksetDataDelete("qs:occ:" + (string)b);

    // Rows swapped; the running animations have not. core re-resolves,
    // which reapplies both with the new occupants and their own personal
    // offsets.
    llMessageLinked(LINK_SET, QSC_RESYNC, "", "");
}

boot_up()
{
    load_from_lsd();
    resolve_bindings();
    place_sittargets();
    llPassTouches(MTYPE > 2);
    rescan_occupancy();
    Out(1, "ready, seats=" + (string)(llGetListLength(SEATS) / SEAT_STRIDE)
        + " mem=" + (string)llGetFreeMemory());
}

default
{
    state_entry()
    {
        // Presence for boot's self-check. seat cannot answer QSALIVE:
        // hudadmin sizes its SITTERS list from that reply, so exactly one
        // script may answer it and that is core. The flag is the same
        // mechanism the plugins use, and boot wipes ^qs:alive: before
        // every CENSUS, so a stamp only counts while we are here to
        // re-place it.
        llLinksetDataWrite("qs:alive:seat", "1");
        boot_up();
    }

    // Same reason as core: v1.s boot announces nothing, it writes
    // qs:meta:<ch> and lets the sitters notice. Without this a seat that
    // started before boot finished has no seats at all.
    linkset_data(integer act, string name, string val)
    {
        if (name == "qs:meta:0" || act == LINKSETDATA_RESET) boot_up();
    }

    run_time_permissions(integer perm)
    {
        // Retry path only; see the header. Drains every parked start
        // that belongs to the avatar this grant is for, and checks the
        // seat still records them so a stand-up in the gap is a no-op.
        if (!(perm & PERMISSION_TRIGGER_ANIMATION)) return;
        key av = llGetPermissionsKey();

        integer s = 0;
        while (s < llGetListLength(PENDING_STOP))
        {
            if (llList2String(PENDING_STOP, s) == (string)av)
            {
                if (av_link(av) != 0)
                    llStopAnimation(llList2String(PENDING_STOP, s + 1));
                PENDING_STOP = llDeleteSubList(PENDING_STOP, s, s + 1);
            }
            else s += 2;
        }

        integer i = 0;
        while (i < llGetListLength(PENDING))
        {
            if (llList2String(PENDING, i) == (string)av)
            {
                integer seat = llList2Integer(PENDING, i + 1);
                string anim  = llList2String(PENDING, i + 2);
                if (llList2String(SEATS, seat * SEAT_STRIDE + 1) == (string)av)
                {
                    string old = llList2String(SEATS, seat * SEAT_STRIDE + 2);
                    if (anim != "") llStartAnimation(anim);
                    SEATS = llListReplaceList(SEATS, [anim],
                        seat * SEAT_STRIDE + 2, seat * SEAT_STRIDE + 2);
                    // The overlap sleep is pointless here: the avatar sat
                    // in the default pose the whole wait, so there is no
                    // running pose to blend out of.
                    if (old != "") { if (old != anim) llStopAnimation(old); }
                    Out(1, "parked grant landed, seat " + (string)seat
                        + " now playing " + anim);
                }
                PENDING = llDeleteSubList(PENDING, i, i + 2);
            }
            else i += 3;
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK)
        {
            rescan_occupancy();
            return;
        }
        if (change & (CHANGED_REGION_START | CHANGED_OWNER))
        {
            // Sit targets do not always survive a region restart, and the
            // occupants keep their seats but lose their animation, so the
            // targets have to be replaced AND the poses re-applied.
            place_sittargets();
            rescan_occupancy();
            llMessageLinked(LINK_SET, QSC_RESYNC, "", "");
        }
    }

    touch_start(integer total)
    {
        integer seat = seat_of_link(llDetectedLinkNumber(0));
        if (seat < 0) seat = 0;
        // ONE message, not two. This also sent AV_MENUTOUSER (90005), and
        // menu answers 90005 and QSS_TOUCH with the same handler, so every
        // touch opened TWO dialogs. menu keeps listening on 90005 for
        // outside senders - plugins and the HUD use it - but the touch
        // path is internal and only needs the v2 number.
        llMessageLinked(LINK_SET, QSS_TOUCH, (string)seat, llDetectedKey(0));
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSC_APPLY)
        {
            // core has resolved everything: which seats take part, which
            // animation each gets, and the final position and rotation.
            //
            // TWO PASSES WITH ONE SHARED SLEEP, and the shape is
            // load-bearing. v1 overlaps per avatar (start new, sleep 0.2,
            // stop old) so nobody drops into their default pose for a
            // frame. That sleep would tear this loop apart in the middle,
            // so the overlap moves outside it: start everybody, sleep
            // once, stop everybody. The starts stay inside one frame,
            // which is the SYNC property, and the stops end up
            // synchronous with each other as well - something v1 never
            // managed across N independent scripts.
            //
            // Verified in-world 2026-07-29, see qs2/test/permtest.lsl.
            // Payload rows: "<seat>=<anim>=<pos>=<rot>", "|" separated.
            list rows = llParseString2List(msg, ["|"], []);
            integer n = llGetListLength(rows);
            list touched;                      // strided 2: seat, old anim
            integer i = 0;
            while (i < n)
            {
                list f = llParseString2List(llList2String(rows, i), ["="], []);
                integer seat = (integer)llList2String(f, 0);
                if (seat >= 0)
                {
                    if (seat < llGetListLength(SEATS) / SEAT_STRIDE)
                    {
                        string anim = llList2String(f, 1);
                        string old  = llList2String(SEATS, seat * SEAT_STRIDE + 2);
                        vector bp = (vector)llList2String(f, 2);
                        vector br = (vector)llList2String(f, 3);
                        SEATS = llListReplaceList(SEATS, [bp],
                            seat * SEAT_STRIDE + 3, seat * SEAT_STRIDE + 3);
                        SEATS = llListReplaceList(SEATS, [br],
                            seat * SEAT_STRIDE + 4, seat * SEAT_STRIDE + 4);
                        set_seat_target(seat, bp, llEuler2Rot(br * DEG_TO_RAD));
                        // Target for the next sit, prim params for the
                        // person already sitting. v1 does both here too.
                        move_occupant(seat, bp, br);
                        if (anim != old)
                        {
                            if (seat_start(seat, anim))
                            {
                                SEATS = llListReplaceList(SEATS, [anim],
                                    seat * SEAT_STRIDE + 2, seat * SEAT_STRIDE + 2);
                                touched += [seat, old];
                            }
                        }
                    }
                }
                ++i;
            }

            integer t = llGetListLength(touched);
            if (t == 0) return;

            llSleep(0.2);                      // the overlap, once for everybody

            i = 0;
            while (i < t)
            {
                seat_stop(llList2Integer(touched, i), llList2String(touched, i + 1));
                i += 2;
            }
            return;
        }

        if (num == QSS_NUDGE)
        {
            // Live preview while somebody nudges their personal offset.
            // "<seat>=<posDelta>=<rotDelta>", applied on top of whatever
            // the pose already resolved to, so releasing the dialog
            // without saving and re-applying the pose puts it back.
            list f = llParseString2List(msg, ["="], []);
            integer seat = (integer)llList2String(f, 0);
            if (seat < 0) return;
            if (seat >= llGetListLength(SEATS) / SEAT_STRIDE) return;
            vector np = llList2Vector(SEATS, seat * SEAT_STRIDE + 3)
                      + (vector)llList2String(f, 1);
            vector nr = llList2Vector(SEATS, seat * SEAT_STRIDE + 4)
                      + (vector)llList2String(f, 2);
            set_seat_target(seat, np, llEuler2Rot(nr * DEG_TO_RAD));
            move_occupant(seat, np, nr);
            return;
        }

        if (num == AV_HELPERMOVED)
        {
            // The HUD's adjust arrows, and [AV]helper, land here. msg is
            // the seat, id is "<absPos>|<eulerRotDeg>|" and BOTH ARE
            // ABSOLUTE: hudproxy has already added the personal offset
            // (hudproxy.lsl:713), so adding the seat's base here would
            // apply it twice.
            //
            // v1 took this in sitA and ran it through
            // sit_using_prim_params; in v2 the sit target belongs to
            // seat, so it is the only script that can honour it.
            //
            // Nothing is persisted. Saving is the HUD's own 90262 to
            // [QS]offset, and a re-applied pose is meant to snap back to
            // the stored value when the operator never pressed [SAVE].
            integer seat = (integer)msg;
            if (seat < 0) return;
            if (seat >= llGetListLength(SEATS) / SEAT_STRIDE) return;
            list f = llParseString2List((string)id, ["|"], []);
            // Prim params ONLY, no sit target. v1 does the same here
            // (sitA.lsl:1241): this is a transient personal offset, and
            // the seat's stored default must survive it so re-applying
            // the pose without a [SAVE] puts things back.
            move_occupant(seat, (vector)llList2String(f, 0),
                (vector)llList2String(f, 1));
            return;
        }

        if (num == QSS_SWAP)
        {
            list f = llParseString2List(msg, ["|"], []);
            swap_seats((integer)llList2String(f, 0), (integer)llList2String(f, 1));
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            boot_up();
            return;
        }

        if (num == QS_ALIVE_CENSUS)
        {
            llLinksetDataWrite("qs:alive:seat", "1");
            return;
        }
    }
}
