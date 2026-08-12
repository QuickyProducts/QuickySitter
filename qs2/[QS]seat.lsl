/*
 * [QS]seat - QuickySitter v2 occupancy engine
 *
 * Singleton, despite the singular name: it manages every seat of every
 * item. It owns WHO SITS WHERE. [QS]core owns WHAT GETS PLAYED.
 *
 * Responsibilities: prim binding, sit targets, the occupancy table, the
 * sit/stand lifecycle, seat swapping, and driving the animations.
 *
 * WHY THIS IS NOT [QS]core
 *
 * The split costs nothing on the hot path because occupancy lives in LSD
 * (qs:occ:*), written here and read directly by core rather than asked
 * for. At pose start core resolves everything and sends one QSC_APPLY.
 * That is as much wire as today's sitB→sitA hop, so it is not a
 * regression. See qs2/DESIGN.md §2 and §6.4.
 *
 * ADDRESSING. Two layers, deliberately separate:
 *   names   <item>/<seat>, used by LSD and the notecard
 *   slots   integers enumerated across all items in declaration order,
 *           used on the wire so stock AVsitter plugins keep working
 * This script owns the mapping and is the only one that needs both.
 *
 * IT DRIVES THE ANIMATIONS ITSELF. There is no per-seat animator script,
 * and an earlier draft of this design had one.
 *
 * Measured in-world 2026-07-29 (DESIGN.md §3): the permission grant is
 * synchronous for an avatar already seated on the object, so a single
 * handler can acquire and start every occupant in turn. 1.2 ms per seat,
 * so eight seats fit inside a 22 ms frame with room to spare. That is
 * what keeps SYNC couple poses in phase, and it is tighter than N
 * independent scripts managed, because there is no scheduling boundary
 * between the calls.
 *
 * run_time_permissions is deliberately NOT handled. It arrives after the
 * work is already done, fires once per request, and always reports the
 * LAST key, so it cannot even tell the requests apart.
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.01";

integer QSS_OCCUPIED = 90410;
integer QSS_VACATED  = 90411;
integer QSS_TOUCH    = 90412;
integer QSS_SEATED   = 90413;
integer QSS_SWAP     = 90414;

integer QSC_APPLY   = 90421;
integer QSC_RESYNC  = 90423;

integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

// Stock AVsitter numbers, emitted alongside the v2 wire so stock plugins
// keep working. They carry the slot integer, which is why this script
// owns the name↔slot mapping (DESIGN.md §7.5).
integer AV_NEWSITTER = 90060;
integer AV_SITTERGONE = 90065;

// ITEMS strided 3: name, firstSeat, seatCount
list ITEMS;
// SEATS strided 5: name, primLink, occupant, primNameOverride, currentAnim
// occupant is "" when free (an LSL key defaults to "", never NULL_KEY).
list SEATS;
integer SEAT_STRIDE = 5;
integer ITEM_STRIDE = 3;

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
        if (llList2Integer(SEATS, i + 1) == link) return i / SEAT_STRIDE;
        i += SEAT_STRIDE;
    }
    return -1;
}

integer seat_of_avatar(key av)
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    while (i < n)
    {
        if (llList2String(SEATS, i + 2) == (string)av) return i / SEAT_STRIDE;
        i += SEAT_STRIDE;
    }
    return -1;
}

integer item_of_seat(integer seat)
{
    integer i = 0;
    integer n = llGetListLength(ITEMS);
    while (i < n)
    {
        integer first = llList2Integer(ITEMS, i + 1);
        if (seat >= first)
        {
            if (seat < first + llList2Integer(ITEMS, i + 2)) return i / ITEM_STRIDE;
        }
        i += ITEM_STRIDE;
    }
    return -1;
}

integer seat_by_name(string item, string seat)
{
    integer it = 0;
    integer n = llGetListLength(ITEMS);
    while (it < n)
    {
        if (llList2String(ITEMS, it) == item)
        {
            integer first = llList2Integer(ITEMS, it + 1);
            integer cnt   = llList2Integer(ITEMS, it + 2);
            integer s = first;
            while (s < first + cnt)
            {
                if (llList2String(SEATS, s * SEAT_STRIDE) == seat) return s;
                ++s;
            }
            return -1;
        }
        it += ITEM_STRIDE;
    }
    return -1;
}

string addr_of_seat(integer seat)
{
    integer it = item_of_seat(seat);
    if (it < 0) return "";
    return llList2String(ITEMS, it * ITEM_STRIDE) + "/"
         + llList2String(SEATS, seat * SEAT_STRIDE);
}

// ------------------------------------------------------------- LSD load

load_from_lsd()
{
    ITEMS = [];
    SEATS = [];

    string v = llLinksetDataRead("qs:cfg:verbose");
    if (v != "") verbose = (integer)v;

    integer ic = (integer)llLinksetDataRead("qs:i:count");
    integer i = 0;
    while (i < ic)
    {
        list p = llParseString2List(llLinksetDataRead("qs:i:" + (string)i), ["|"], []);
        ITEMS += [ llList2String(p, 0)
                 , llList2Integer(p, 1)
                 , llList2Integer(p, 2) ];
        ++i;
    }

    integer sc = (integer)llLinksetDataRead("qs:s:count");
    i = 0;
    while (i < sc)
    {
        list p = llParseString2List(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
        // name, primLink (resolved below), occupant, primName override, currentAnim
        SEATS += [ llList2String(p, 0), 0, "", llList2String(p, 1), "" ];
        llLinksetDataWrite("qs:slot:" + llList2String(p, 0), (string)i);
        ++i;
    }
}

// -------------------------------------------------------- prim binding

// An item binds to every prim carrying its NAME. Prim name and prim
// description are the only rez- and relink-stable identifiers in SL, so
// this is the one thing a creator can rely on. A seat may override with
// its own prim name; otherwise the item's prims are handed to its seats
// in link order.
//
// Replaces the v1 "#<SET>-<slot>" description code, which nobody found
// in the build tool.
resolve_bindings()
{
    integer links = llGetNumberOfPrims();
    integer it = 0;
    integer itn = llGetListLength(ITEMS);
    while (it < itn)
    {
        string iname = llList2String(ITEMS, it);
        integer first = llList2Integer(ITEMS, it + 1);
        integer cnt   = llList2Integer(ITEMS, it + 2);

        // Collect this item's prims in link order.
        list mine;
        integer l = 1;
        while (l <= links)
        {
            if (llGetLinkName(l) == iname) mine += l;
            ++l;
        }

        integer s = 0;
        integer taken = 0;
        while (s < cnt)
        {
            integer row = (first + s) * SEAT_STRIDE;
            string override = llList2String(SEATS, row + 3);
            integer link = 0;
            if (override != "")
            {
                integer k = 1;
                while (k <= links)
                {
                    if (llGetLinkName(k) == override) { link = k; k = links; }
                    ++k;
                }
            }
            else
            {
                if (taken < llGetListLength(mine))
                {
                    link = llList2Integer(mine, taken);
                    ++taken;
                }
            }
            SEATS = llListReplaceList(SEATS, [link], row + 1, row + 1);
            ++s;
        }
        it += ITEM_STRIDE;
    }
}

// SL allows one sit target per prim, so a seat without a prim cannot be
// sat on. That is the v2 shape of the old "not enough prims for required
// SitTargets" error.
place_sittargets()
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    integer missing = 0;
    while (i < n)
    {
        integer link = llList2Integer(SEATS, i + 1);
        if (link > 0)
            llLinkSitTarget(link, <0.0, 0.0, 0.1>, ZERO_ROTATION);
        else
            ++missing;
        i += SEAT_STRIDE;
    }
    if (missing)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + (string)missing
            + " seat(s) have no prim. Name a prim after the item, or give the"
            + " seat an explicit PRIM.");
}

// Offsets are local to the seat's own prim (FORMAT.md §2), so there is
// exactly one frame of reference and no LROT/REFERENCE conversion. The
// -0.4 Z shift and the small nudge along the target's up axis are the
// AVsitter convention for turning a pose position into a sit target.
set_seat_target(integer seat, vector pos, rotation rot)
{
    integer link = llList2Integer(SEATS, seat * SEAT_STRIDE + 1);
    if (link <= 0) return;
    llLinkSitTarget(link, pos - <0.0, 0.0, 0.4> + llRot2Up(rot) * 0.05, rot);
}

// ------------------------------------------------------------ animation

// Acquire this seat's occupant and start an animation on them.
//
// Permission is taken per call rather than held, because a script holds
// it for exactly one avatar at a time (llGetPermissionsKey is single
// valued). Acquiring it at sit time would therefore be pointless: the
// next seat overwrites it immediately. Measured cost is 1.2 ms.
//
// Losing the permission does NOT stop a running animation, which is the
// property this whole design rests on.
integer seat_start(integer seat, string anim)
{
    integer row = seat * SEAT_STRIDE;
    key av = (key)llList2String(SEATS, row + 2);
    if (av == "") return FALSE;
    llRequestPermissions(av, PERMISSION_TRIGGER_ANIMATION);
    if (!(llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)) return FALSE;
    if (anim != "") llStartAnimation(anim);
    return TRUE;
}

seat_stop(integer seat, string anim)
{
    if (anim == "") return;
    integer row = seat * SEAT_STRIDE;
    key av = (key)llList2String(SEATS, row + 2);
    if (av == "") return;
    llRequestPermissions(av, PERMISSION_TRIGGER_ANIMATION);
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        llStopAnimation(anim);
}

// ---------------------------------------------------------- lifecycle

seat_taken(integer seat, key av)
{
    integer row = seat * SEAT_STRIDE;
    SEATS = llListReplaceList(SEATS, [(string)av], row + 2, row + 2);

    string addr = addr_of_seat(seat);
    llLinksetDataWrite("qs:occ:" + addr, (string)av);

    // core can be told straight away. The earlier design had to wait for
    // a permission grant to land before a pose could start; permission is
    // now taken at animation time, so there is nothing to wait for.
    llMessageLinked(LINK_SET, QSS_OCCUPIED, addr, av);
    llMessageLinked(LINK_SET, AV_NEWSITTER, (string)seat, av);
    llMessageLinked(LINK_SET, QSS_SEATED, addr, av);
}

seat_freed(integer seat, key was)
{
    integer row = seat * SEAT_STRIDE;
    string addr = addr_of_seat(seat);

    // Standing up revokes the permission and stops the animation by
    // itself, so this is bookkeeping. The explicit stop matters on the
    // other path, where the seat is freed while the avatar is still on
    // it (a swap, or a takeover).
    seat_stop(seat, llList2String(SEATS, row + 4));
    SEATS = llListReplaceList(SEATS, [""], row + 2, row + 2);
    SEATS = llListReplaceList(SEATS, [""], row + 4, row + 4);
    llLinksetDataDelete("qs:occ:" + addr);
    llLinksetDataDelete("qs:cur:" + addr);
    llMessageLinked(LINK_SET, QSS_VACATED, addr, was);
    llMessageLinked(LINK_SET, AV_SITTERGONE, (string)seat, was);
}

// One pass over every seat prim, diffed against the occupancy column.
// This replaces the per-instance changed() handlers of v1 and the
// messages that kept their SITTERS lists in step.
rescan_occupancy()
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    integer seat = 0;
    while (i < n)
    {
        integer link = llList2Integer(SEATS, i + 1);
        key now = "";
        if (link > 0) now = llAvatarOnLinkSitTarget(link);
        if (now == NULL_KEY) now = "";

        string before = llList2String(SEATS, i + 2);
        if ((string)now != before)
        {
            if (before != "") seat_freed(seat, (key)before);
            if (now != "")    seat_taken(seat, now);
        }
        i += SEAT_STRIDE;
        ++seat;
    }
}

// Swap is a row swap plus new sit targets. In v1 this was ~80 lines of
// protocol between two independent script instances.
swap_seats(integer a, integer b)
{
    if (a < 0 || b < 0) return;
    if (a == b) return;
    integer ra = a * SEAT_STRIDE;
    integer rb = b * SEAT_STRIDE;
    string occA = llList2String(SEATS, ra + 2);
    string occB = llList2String(SEATS, rb + 2);
    string anA  = llList2String(SEATS, ra + 4);
    string anB  = llList2String(SEATS, rb + 4);

    SEATS = llListReplaceList(SEATS, [occB], ra + 2, ra + 2);
    SEATS = llListReplaceList(SEATS, [occA], rb + 2, rb + 2);
    SEATS = llListReplaceList(SEATS, [anB],  ra + 4, ra + 4);
    SEATS = llListReplaceList(SEATS, [anA],  rb + 4, rb + 4);

    string addrA = addr_of_seat(a);
    string addrB = addr_of_seat(b);
    if (occB != "") llLinksetDataWrite("qs:occ:" + addrA, occB);
    else            llLinksetDataDelete("qs:occ:" + addrA);
    if (occA != "") llLinksetDataWrite("qs:occ:" + addrB, occA);
    else            llLinksetDataDelete("qs:occ:" + addrB);

    // Rows and sit targets have swapped; the running animations have not.
    // Ask core to re-resolve, which reapplies both with the new occupants
    // and their own personal offsets.
    integer it = item_of_seat(a);
    if (it >= 0)
        llMessageLinked(LINK_SET, QSC_RESYNC,
            llList2String(ITEMS, it * ITEM_STRIDE), "");
}

boot_up()
{
    load_from_lsd();
    resolve_bindings();
    place_sittargets();
    rescan_occupancy();
    Out(1, "ready, items=" + (string)(llGetListLength(ITEMS) / ITEM_STRIDE)
        + " seats=" + (string)(llGetListLength(SEATS) / SEAT_STRIDE)
        + " mem=" + (string)llGetFreeMemory());
}

default
{
    state_entry()
    {
        boot_up();
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
            integer i = 0;
            integer n = llGetListLength(ITEMS);
            while (i < n)
            {
                llMessageLinked(LINK_SET, QSC_RESYNC, llList2String(ITEMS, i), "");
                i += ITEM_STRIDE;
            }
        }
    }

    touch_start(integer total)
    {
        // The touched prim IS the address. Resolving it to an item is why
        // clicking the bed opens the bed menu and clicking the chair opens
        // the chair menu, with no slot numbering anywhere.
        integer link = llDetectedLinkNumber(0);
        integer seat = seat_of_link(link);
        string item = "";
        if (seat >= 0)
        {
            integer it = item_of_seat(seat);
            if (it >= 0) item = llList2String(ITEMS, it * ITEM_STRIDE);
        }
        else
        {
            // Not a seat prim, but it may still carry an item's name
            // (a bed frame, a cushion).
            string lname = llGetLinkName(link);
            integer i = 0;
            integer n = llGetListLength(ITEMS);
            while (i < n)
            {
                if (llList2String(ITEMS, i) == lname) { item = lname; i = n; }
                i += ITEM_STRIDE;
            }
        }
        if (item == "") return;
        llMessageLinked(LINK_SET, QSS_TOUCH, item, llDetectedKey(0));
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
            string item = (string)id;
            list rows = llParseString2List(msg, ["|"], []);
            integer n = llGetListLength(rows);

            list touched;      // seat indices we started, strided 2 with old anim
            integer i = 0;
            while (i < n)
            {
                list f = llParseString2List(llList2String(rows, i), ["="], []);
                integer seat = seat_by_name(item, llList2String(f, 0));
                if (seat >= 0)
                {
                    string anim = llList2String(f, 1);
                    string old  = llList2String(SEATS, seat * SEAT_STRIDE + 4);
                    set_seat_target(seat, (vector)llList2String(f, 2),
                        llEuler2Rot((vector)llList2String(f, 3) * DEG_TO_RAD));
                    if (anim != old)
                    {
                        if (seat_start(seat, anim))
                        {
                            SEATS = llListReplaceList(SEATS, [anim],
                                seat * SEAT_STRIDE + 4, seat * SEAT_STRIDE + 4);
                            touched += [seat, old];
                        }
                    }
                }
                ++i;
            }

            integer t = llGetListLength(touched);
            if (t == 0) return;

            llSleep(0.2);      // the overlap, once for everybody

            i = 0;
            while (i < t)
            {
                seat_stop(llList2Integer(touched, i), llList2String(touched, i + 1));
                i += 2;
            }
            return;
        }

        if (num == QSS_SWAP)
        {
            list f = llParseString2List(msg, ["|"], []);
            list a = llParseString2List(llList2String(f, 0), ["/"], []);
            swap_seats(seat_by_name(llList2String(a, 0), llList2String(a, 1)),
                       seat_by_name(llList2String(a, 0), llList2String(f, 1)));
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            boot_up();
            return;
        }
    }
}
