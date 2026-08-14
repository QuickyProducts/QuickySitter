string version = "0.22";

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

// Per-seat gender from the notecard.s SITTER directives, cfg field 16:
// 1 male, 0 female, -1 unassigned. Empty when the notecard declares
// none, and then regender is a no-op.
list GENDERS;

integer MTYPE;
integer SET;                       // cfg field 2; a prim pin only counts
                                   // when its SET matches this furniture

// SINGLE-PRIM MODE (DESIGN.md §10). Detected, not configured: a one-prim
// object with more than one seat cannot be classic furniture, and classic
// furniture is never one prim, so the two modes cannot be confused.
//
// In this mode the sit target is a DOOR, not a place: it exists so the
// prim is sittable at all (measured: a prim with no target cannot be sat
// on), it is consumed by each arrival (measured: one llSitTarget call
// admits exactly one sitter), and it is re-armed with an alternating
// epsilon because a call that sets the value it already holds is a
// no-op. Where the arrival LANDS is SL's click-relative placement, which
// is what seats are picked from; where they SIT is move_occupant's job,
// as everywhere else.
//
// KNOWN, ACCEPTED FOR THE PROTOTYPE:
//   - between an arrival and the re-arm the prim admits nobody, so two
//     people sitting in the same instant lose one of them (they simply
//     do not sit; no event fires anywhere)
//   - CLICK_ACTION_SIT takes the left click, so non-sitters cannot open
//     the menu by clicking the furniture (the MTYPE/ETYPE question,
//     still undecided)
integer ONEPRIM;
integer armcount;

// Animation starts whose permission grant did not come back
// synchronously, strided 3: avatar, seat, anim. Retried from
// run_time_permissions when the grant lands. Rows for somebody who
// stood up in the meantime die on the occupant check there.
list PENDING;

// Same, for the stop half of a pose change, strided 2: avatar, anim.
list PENDING_STOP;

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
            if (llGetListLength(data) == 2
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
        if (i != seat)
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
// The door target. llSitTarget rather than llLinkSitTarget: the script
// lives in the one prim there is, and a lone prim's link number shifts
// between 0 and 1 depending on whether anyone is seated.
arm_door()
{
    ++armcount;
    llSitTarget(<0.0, 0.0, 0.1 + 0.0001 * (float)(armcount % 2)>,
        ZERO_ROTATION);
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
integer pick_seat(vector p)
{
    integer seats = llGetListLength(SEATS) / SEAT_STRIDE;
    integer best = -1;
    float bestd = -1.0;
    integer i = 0;
    while (i < seats)
    {
        if (llList2String(SEATS, i * SEAT_STRIDE + 1) == "")
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
    if (ONEPRIM)
    {
        // The whole prim seats on left click, which is what carries the
        // click point through to the landing position (measured: with
        // the default click action, deliberate end-clicks failed to
        // seat at all).
        llSetClickAction(CLICK_ACTION_SIT);
        arm_door();
        return;
    }

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
    // In single-prim mode the target is the DOOR and nothing else may
    // write it: seat 0 is bound to the prim, and letting its pose apply
    // land here would re-aim the door at seat 0's pose - which is
    // exactly the value an arrival must NOT inherit.
    if (ONEPRIM) return;

    integer link = llList2Integer(SEATS, seat * SEAT_STRIDE);
    if (link <= 0) return;

    // v1 suppresses the target entirely on an excluded prim
    // (sitA.lsl:458), so a prim marked "never seat anyone here" cannot be
    // sat on even if the binding somehow handed it out.
    string desc = llList2String(llGetLinkPrimitiveParams(link, [PRIM_DESC]), 0);
    desc = llGetSubString(desc, llSubStringIndex(desc, "#") + 1, 99999);
    if (desc == "-1") return;

    // SAME FRAME QUESTION AS move_occupant, and v1 answers it here with
    // an explicit conversion (sitA.lsl:434). The pose is in the script
    // prim's frame; a sit target is written in the TARGET prim's local
    // frame. When they are the same prim there is nothing to do, which
    // is the common single-seat case.
    vector   tp = pos;
    rotation tr = rot;
    if (link != llGetLinkNumber())
    {
        vector   lp = ZERO_VECTOR;
        rotation lr = ZERO_ROTATION;
        if (llGetLinkNumber() > 1)
        {
            lp = llGetLocalPos();
            lr = llGetLocalRot();
        }
        tp = lp + pos * lr;                       // -> root frame
        tr = rot * lr;
        if (link > 1)
        {
            list p = llGetLinkPrimitiveParams(link,
                [PRIM_POS_LOCAL, PRIM_ROT_LOCAL]);
            rotation tlr = llList2Rot(p, 1);
            tp = (tp - llList2Vector(p, 0)) / tlr;  // -> target prim frame
            tr = tr / tlr;
        }
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
    // Stage 2 intends to make offsets seat-prim-local and drop this
    // (DESIGN.md §6.4). Until the notecard format changes with it,
    // stage-1 data was authored under v1's rule and has to be read under
    // v1's rule.
    vector   lp = ZERO_VECTOR;
    rotation lr = ZERO_ROTATION;
    if (llGetLinkNumber() > 1)
    {
        lp = llGetLocalPos();
        lr = llGetLocalRot();
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

// One pass over every seat prim, diffed against the occupancy column.
// Replaces the per-instance changed() handlers of v1 and the messages
// that kept their SITTERS lists in step.
// Single-prim discovery: diff the agent links against the table. STILL
// SELF-HEALING, which was the stated worry about leaving the per-prim
// lookup: the agent links are themselves re-derivable truth, walked in
// full on every scan, so a missed CHANGED_LINK is repaired by the next
// one rather than desynchronising the table forever. What is genuinely
// new is only the seat CHOICE for an arrival, which reads the landing
// position SL computed from the click.
rescan_oneprim()
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
                integer pick = pick_seat(p);
                if (pick == -1)
                {
                    // Every seat taken. v1 cannot get here - the sim
                    // refuses the sit when all targets are occupied - so
                    // there is no behaviour to copy, and leaving them
                    // seated but unanimated on top of somebody would be
                    // worse than the eject.
                    Out(0, "no free seat for " + llKey2Name(av) + ", unsitting.");
                    llUnSit(av);
                }
                else
                {
                    Out(2, "landed at " + (string)p + " -> seat "
                        + (string)pick);
                    seat_taken(regender(pick, av), av);
                }
                // Consumed by this arrival either way.
                arm_door();
            }
        }
        ++l;
    }
}

rescan_occupancy()
{
    if (ONEPRIM) { rescan_oneprim(); return; }

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
            if (now != "")
            {
                // regender may hand back a different seat, having swapped
                // the prim bindings. The rest of this scan stays correct
                // either way: the seat it moved to now points at the prim
                // the arrival is on, and seat_taken has already recorded
                // them there, so that row reads as unchanged. The seat
                // they came from now points at a free prim and reads as
                // empty, which it is.
                seat_taken(regender(seat, now), now);
            }
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
    // Object prim count, so seated avatars do not flip the mode off:
    // llGetNumberOfPrims counts them and would read 3 with two sitters.
    ONEPRIM = FALSE;
    if (llGetObjectPrimCount(llGetKey()) == 1)
    {
        if (llGetListLength(SEATS) / SEAT_STRIDE > 1) ONEPRIM = TRUE;
    }
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
