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
 * run_time_permissions is deliberately NOT handled. It arrives after the
 * work is done, fires once per request, and always reports the LAST key,
 * so it cannot even tell the requests apart.
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.12";

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

integer MTYPE;
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

// v1 rules, unchanged, because this is a drop-in: a prim description of
// "#<SET>-<slot>" pins that prim to that slot, "-1" excludes a prim, and
// anything unpinned is handed out in link order.
resolve_bindings()
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer links = llGetNumberOfPrims();
    list free_links;
    list pinned;                       // strided 2: slot, link

    integer l = 1;
    while (l <= links)
    {
        string desc = llList2String(llGetLinkPrimitiveParams(l, [PRIM_DESC]), 0);
        if (llGetSubString(desc, 0, 0) == "#")
        {
            list p = llParseString2List(llGetSubString(desc, 1, -1), ["-"], []);
            integer slot = (integer)llList2String(p, 1);
            if (slot >= 0) pinned += [slot, l];
            // slot -1 excludes the prim: neither pinned nor free.
        }
        else
        {
            free_links += l;
        }
        ++l;
    }

    integer s = 0;
    integer taken = 0;
    while (s < seats)
    {
        integer link = 0;
        integer at = llListFindList(pinned, [s]);
        if (at != -1)
        {
            if (at % 2 == 0) link = llList2Integer(pinned, at + 1);
        }
        if (link == 0)
        {
            if (taken < llGetListLength(free_links))
            {
                link = llList2Integer(free_links, taken);
                ++taken;
            }
        }
        SEATS = llListReplaceList(SEATS, [link], s * SEAT_STRIDE, s * SEAT_STRIDE);
        ++s;
    }
}

// SL allows one sit target per prim, so a seat without a prim cannot be
// sat on. Same condition as v1's "not enough prims for required
// SitTargets" (sitA.lsl:33).
place_sittargets()
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    integer missing = 0;
    while (i < n)
    {
        integer link = llList2Integer(SEATS, i);
        if (link > 0) llLinkSitTarget(link, <0.0, 0.0, 0.1>, ZERO_ROTATION);
        else ++missing;
        i += SEAT_STRIDE;
    }
    if (missing)
        llDialog(llGetOwner(), "\nThere aren't enough prims for required"
            + " SitTargets.\nYou must have one prim for each avatar to sit!",
            ["OK"], 23658);
}

// The -0.4 Z shift and the nudge along the target's up axis are the
// AVsitter convention for turning a pose position into a sit target
// (sitA.lsl:460).
set_seat_target(integer seat, vector pos, rotation rot)
{
    integer link = llList2Integer(SEATS, seat * SEAT_STRIDE);
    if (link <= 0) return;
    llLinkSitTarget(link, pos - <0.0, 0.0, 0.4> + llRot2Up(rot) * 0.05, rot);
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

    // The pose is expressed relative to the SEAT's prim. v1 could read
    // llGetLocalPos/Rot because each sitA lived in its own seat prim; a
    // singleton has to ask for the prim it is placing into.
    integer prim = llList2Integer(SEATS, seat * SEAT_STRIDE);
    vector   lp = ZERO_VECTOR;
    rotation lr = ZERO_ROTATION;
    if (prim > 1)
    {
        list p = llGetLinkPrimitiveParams(prim, [PRIM_POS_LOCAL, PRIM_ROT_LOCAL]);
        lp = llList2Vector(p, 0);
        lr = llList2Rot(p, 1);
    }

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
    if (!(llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)) return FALSE;
    if (anim != "") llStartAnimation(anim);
    return TRUE;
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

    integer link = llList2Integer(SEATS, seat * SEAT_STRIDE);
    if (link <= 0) return;
    if (llAvatarOnLinkSitTarget(link) != av) return;   // already gone

    llRequestPermissions(av, PERMISSION_TRIGGER_ANIMATION);
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        llStopAnimation(anim);
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
    llLinksetDataDelete("qs:cur:" + (string)seat);
    llMessageLinked(LINK_SET, QSS_VACATED, (string)seat, was);
    llMessageLinked(LINK_SET, AV_SITTERGONE, (string)seat, was);
}

// One pass over every seat prim, diffed against the occupancy column.
// Replaces the per-instance changed() handlers of v1 and the messages
// that kept their SITTERS lists in step.
rescan_occupancy()
{
    integer i = 0;
    integer n = llGetListLength(SEATS);
    integer seat = 0;
    while (i < n)
    {
        integer link = llList2Integer(SEATS, i);
        key now = "";
        if (link > 0) now = llAvatarOnLinkSitTarget(link);
        if (now == NULL_KEY) now = "";

        string before = llList2String(SEATS, i + 1);
        if ((string)now != before)
        {
            if (before != "") seat_freed(seat, (key)before);
            if (now != "")    seat_taken(seat, now);
        }
        i += SEAT_STRIDE;
        ++seat;
    }
}

// A row swap plus new sit targets. In v1 this was ~80 lines of protocol
// between two independent script instances (90030/90031).
swap_seats(integer a, integer b)
{
    if (a < 0 || b < 0) return;
    if (a == b) return;
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
        // Stock behaviour: a touch asks for the menu on the toucher's
        // behalf. 90005 is the v1 number and plugins listen for it.
        llMessageLinked(LINK_SET, AV_MENUTOUSER, (string)seat, llDetectedKey(0));
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
