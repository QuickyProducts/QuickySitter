/*
 * [QS]core - QuickySitter v2 pose engine
 *
 * Singleton. It owns WHAT GETS PLAYED. [QS]seat owns WHO SITS WHERE.
 *
 * Responsibilities: the pose model, resolving a pose into per-seat
 * animations and positions, default and personal offsets, gender
 * variants, sequences, camera, access gating, and the broadcast that
 * plugins listen to.
 *
 * WHY IT NEVER ASKS WHO IS SITTING
 *
 * Occupancy lives in LSD (qs:occ:*), written by [QS]seat. core reads it
 * directly. That is what keeps the core/seat split off the hot path: a
 * pose start is resolve-then-one-message, not a conversation.
 *
 * NO LISTENER, NO PERMISSIONS, NO CHANGED_LINK. Dialogs belong to
 * [QS]menu, permission to [QS]anim, occupancy to [QS]seat.
 *
 * POSE DATA IN LSD (written by [QS]boot)
 *
 *   qs:p:<item>:count        number of poses in this item
 *   qs:p:<item>:<n>          "<label>|<seat>=<anim>|<seat>=<anim>|…"
 *   qs:o:<item>:<n>:<seat>   "<pos>|<rot>"   default offset, from POS lines
 *   qs:x:<item>:SEQUENCE:<n> "<menuPath>|<label>|<pose>,<secs>,…"
 *   qs:cfg:<item>:CAMERA     "<eyeOffset>|<atOffset>"   optional
 *
 * Personal offsets keep the v1 shape with the v2 address:
 *   QSO:<short>:<item>/<seat>:<label>
 *
 * GENDER. A seat carries M, F or empty. A pose may offer per-gender
 * animation variants as "<seat>=<animM>/<animF>"; a seat whose gender is
 * empty takes the first. Absent a slash, both genders get the same
 * animation, which is the common case.
 *
 * STOCK COMPATIBILITY. The legacy 90045 / 90060 / 90065 broadcasts are
 * emitted alongside the v2 wire, carrying slot integers, so stock
 * AVsitter plugins keep working (DESIGN.md §7.5). 90060/90065 are sent
 * by [QS]seat, which owns occupancy; 90045 is sent here, since it
 * describes the pose.
 *
 * NOT BUILT YET: the keyframed-motion pause/resume path around a pose
 * change, and the HUD wire (that lives in [QS]menu). See qs2/STATUS.md.
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.02";

integer QSS_SEATED  = 90413;
integer QSS_VACATED = 90411;

integer QSC_REQUEST = 90420;
integer QSC_APPLY   = 90421;
integer QSC_PLAYING = 90422;
integer QSC_RESYNC  = 90423;
integer QSC_ALLOWED = 90424;   // core → menu, answer to QSC_MAYI
integer QSC_MAYI    = 90425;   // menu → core, "may this avatar operate <item>"

integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

// Stock AVsitter numbers, emitted for compatibility.
integer AV_POSEPLAYED = 90045;
integer AV_PLUGINPROBE = 90201;
integer AV_PLUGINREPLY = 90202;
integer AV_CAMERA      = 90202;   // sitA→camera used 90202 in the other direction

integer has_security;

// Sequence runner. One at a time per object, which matches v1: a
// sequence drives the whole item, not a single seat.
string  seq_item;
list    seq_steps;      // strided 2: poseLabel, seconds
integer seq_at;

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

string qso_key(key av, string addr, string label)
{
    return "QSO:" + llGetSubString((string)av, 0, 7) + ":" + addr + ":" + label;
}

// ------------------------------------------------------------- access

// Same shape as v1's adjust_allowed(): the owner always passes, otherwise
// the level comes from [QS]root-security via qs:sec:adjust. has_security
// is bound to the existence of a 90202 reply, not to its payload, exactly
// as sitB binds it.
integer allowed(key av)
{
    if (av == llGetOwner()) return TRUE;
    if (!has_security) return FALSE;
    string mode = llLinksetDataRead("qs:sec:adjust");
    if (mode == "ALL") return TRUE;
    if (mode == "GROUP") return llSameGroup(av);
    return FALSE;
}

// A seated avatar may always drive the item it is sitting on. Sitting is
// itself the permission; the gate above is for people who are not.
integer seated_on(key av, string item)
{
    integer n = (integer)llLinksetDataRead("qs:s:count");
    integer i = 0;
    while (i < n)
    {
        list s = llParseString2List(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
        if (llLinksetDataRead("qs:occ:" + item + "/" + llList2String(s, 0)) == (string)av)
            return TRUE;
        ++i;
    }
    return FALSE;
}

// ------------------------------------------------------------- helpers

string seat_field(string item, string seatName, integer idx)
{
    integer n = (integer)llLinksetDataRead("qs:s:count");
    integer i = 0;
    while (i < n)
    {
        list s = llParseStringKeepNulls(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
        if (llList2String(s, 0) == seatName) return llList2String(s, idx);
        ++i;
    }
    return "";
}

integer slot_of(string addr)
{
    string v = llLinksetDataRead("qs:slot:" + addr);
    if (v == "") return 0;
    return (integer)v;
}

// "animM/animF". A seat with no gender takes the first variant, which is
// also what a pose with no slash gives everybody.
string pick_gender(string anim, string gender)
{
    integer cut = llSubStringIndex(anim, "/");
    if (cut == -1) return anim;
    if (gender == "F") return llGetSubString(anim, cut + 1, -1);
    return llGetSubString(anim, 0, cut - 1);
}

list resolve_offset(string item, integer idx, string seatName, string label)
{
    vector pos = ZERO_VECTOR;
    vector rot = ZERO_VECTOR;

    string d = llLinksetDataRead("qs:o:" + item + ":" + (string)idx + ":" + seatName);
    if (d != "")
    {
        list p = llParseString2List(d, ["|"], []);
        pos = (vector)llList2String(p, 0);
        rot = (vector)llList2String(p, 1);
    }

    string addr = item + "/" + seatName;
    key av = (key)llLinksetDataRead("qs:occ:" + addr);
    if (av != "")
    {
        string pers = llLinksetDataRead(qso_key(av, addr, label));
        // M#T! is the reserved "same offset for every pose" entry, kept
        // from v1 unchanged.
        if (pers == "") pers = llLinksetDataRead(qso_key(av, addr, "M#T!"));
        if (pers != "")
        {
            list p = llParseString2List(pers, ["|"], []);
            pos += (vector)llList2String(p, 0);
            rot += (vector)llList2String(p, 1);
        }
    }
    return [pos, rot];
}

// Label alone is NOT a unique pose identity, and a real notecard proves
// it: "Lalou" carries a slot-local POSE named "Sit" in both sitter blocks
// with different animations, and the same for "Phone call" and "Dance".
// They are independent poses that share a label, so the identity is the
// pair (label, participating seat) — which is exactly why no separate ID
// concept is needed, as long as the caller says which seat is asking.
//
// seatName == "" means "any", for callers with no seat (a resync sweep).
integer pose_by_label(string item, string label, string seatName)
{
    integer n = (integer)llLinksetDataRead("qs:p:" + item + ":count");
    integer i = 0;
    while (i < n)
    {
        string row = llLinksetDataRead("qs:p:" + item + ":" + (string)i);
        list f = llParseString2List(row, ["|"], []);
        if (llList2String(f, 0) == label)
        {
            if (seatName == "") return i;
            integer j = 1;
            integer m = llGetListLength(f);
            while (j < m)
            {
                string pair = llList2String(f, j);
                integer cut = llSubStringIndex(pair, "=");
                if (cut > 0)
                {
                    if (llGetSubString(pair, 0, cut - 1) == seatName) return i;
                }
                ++j;
            }
        }
        ++i;
    }
    return -1;
}

// Which seat is this avatar in, within this item. "" when not seated.
string seat_of(key av, string item)
{
    integer n = (integer)llLinksetDataRead("qs:s:count");
    integer i = 0;
    while (i < n)
    {
        list s = llParseString2List(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
        string nm = llList2String(s, 0);
        if (llLinksetDataRead("qs:occ:" + item + "/" + nm) == (string)av) return nm;
        ++i;
    }
    return "";
}

// --------------------------------------------------------------- camera

// Optional per item: "<eyeOffset>|<atOffset>". Applied to every occupant
// of the item when a pose starts, which is when v1 applies it too.
apply_camera(string item)
{
    string c = llLinksetDataRead("qs:cfg:" + item + ":CAMERA");
    if (c == "") return;
    list f = llParseString2List(c, ["|"], []);
    llMessageLinked(LINK_SET, AV_CAMERA, llList2String(f, 0), llList2String(f, 1));
}

// ----------------------------------------------------------- pose start

start_pose(string item, integer idx)
{
    string row = llLinksetDataRead("qs:p:" + item + ":" + (string)idx);
    if (row == "") return;

    list f = llParseString2List(row, ["|"], []);
    string label = llList2String(f, 0);

    string payload = "";
    string sitters = "";
    integer i = 1;
    integer n = llGetListLength(f);
    while (i < n)
    {
        string pair = llList2String(f, i);
        integer cut = llSubStringIndex(pair, "=");
        if (cut > 0)
        {
            string seatName = llGetSubString(pair, 0, cut - 1);
            string anim     = llGetSubString(pair, cut + 1, -1);
            string addr     = item + "/" + seatName;
            key occ = (key)llLinksetDataRead("qs:occ:" + addr);

            // A named but empty seat is skipped, not left half applied.
            if (occ != "")
            {
                anim = pick_gender(anim, seat_field(item, seatName, 2));
                list o = resolve_offset(item, idx, seatName, label);
                if (payload != "") payload += "|";
                payload += seatName + "=" + anim
                         + "=" + (string)llList2Vector(o, 0)
                         + "=" + (string)llList2Vector(o, 1);
                llLinksetDataWrite("qs:cur:" + addr, label);
                if (sitters != "") sitters += "@";
                sitters += (string)occ;
            }
        }
        ++i;
    }

    if (payload == "") return;
    llMessageLinked(LINK_SET, QSC_APPLY, payload, item);
    llMessageLinked(LINK_SET, QSC_PLAYING, item + "|" + label, "");
    apply_camera(item);

    // Stock AVsitter pose-played broadcast. Slot integers on the wire,
    // names in LSD: that separation is what lets stock plugins keep
    // working on v2 (DESIGN.md §7.5). Fields follow v1's sitA:571 shape.
    llMessageLinked(LINK_SET, AV_POSEPLAYED,
        llDumpList2String([slot_of(item + "/" + llList2String(
            llParseString2List(llList2String(f, 1), ["="], []), 0)),
            label, "", 0, sitters, 0, 1], "|"), "");

    Out(2, "play " + item + " / " + label);
}

start_default(string item)
{
    if ((integer)llLinksetDataRead("qs:p:" + item + ":count") > 0)
        start_pose(item, 0);
}

// ------------------------------------------------------------ sequences

// "<menuPath>|<label>|<pose>,<secs>,<pose>,<secs>,…"
seq_start(string item, string label)
{
    integer n = (integer)llLinksetDataRead("qs:x:" + item + ":SEQUENCE:count");
    integer i = 0;
    while (i < n)
    {
        list f = llParseString2List(
            llLinksetDataRead("qs:x:" + item + ":SEQUENCE:" + (string)i), ["|"], []);
        if (llList2String(f, 1) == label)
        {
            seq_item  = item;
            seq_steps = llParseString2List(llList2String(f, 2), [","], []);
            seq_at    = 0;
            i = n;
            // Fire the first step immediately; the timer only paces the rest.
            integer at = pose_by_label(item, llList2String(seq_steps, 0), "");
            if (at >= 0) start_pose(item, at);
            llSetTimerEvent((float)llList2String(seq_steps, 1));
            return;
        }
        ++i;
    }
}

seq_stop()
{
    seq_item = "";
    seq_steps = [];
    llSetTimerEvent(0.0);
}

default
{
    state_entry()
    {
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        has_security = FALSE;
        // Same handshake v1 uses: ask, and treat a reply as proof that
        // [QS]root-security exists.
        llMessageLinked(LINK_SET, AV_PLUGINPROBE, "", "");
        Out(1, "ready, mem=" + (string)llGetFreeMemory());
    }

    timer()
    {
        if (seq_item == "") { llSetTimerEvent(0.0); return; }
        seq_at += 2;
        if (seq_at >= llGetListLength(seq_steps)) seq_at = 0;   // loop, as v1 does
        integer at = pose_by_label(seq_item, llList2String(seq_steps, seq_at), "");
        if (at >= 0) start_pose(seq_item, at);
        llSetTimerEvent((float)llList2String(seq_steps, seq_at + 1));
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSS_SEATED)
        {
            integer cut = llSubStringIndex(msg, "/");
            if (cut > 0) start_default(llGetSubString(msg, 0, cut - 1));
            return;
        }

        if (num == QSS_VACATED)
        {
            // A sequence is an item-level effect; with the item empty it
            // has nothing left to drive.
            if (seq_item != "")
            {
                integer cut = llSubStringIndex(msg, "/");
                if (cut > 0)
                {
                    if (llGetSubString(msg, 0, cut - 1) == seq_item) seq_stop();
                }
            }
            return;
        }

        if (num == QSC_MAYI)
        {
            // menu asks before opening. Answer carries the same msg back
            // so menu can match it to the operator without extra state.
            integer ok = FALSE;
            if (seated_on(id, msg)) ok = TRUE;
            else ok = allowed(id);
            llMessageLinked(LINK_SET, QSC_ALLOWED, msg + "|" + (string)ok, id);
            return;
        }

        if (num == QSC_REQUEST)
        {
            list f = llParseString2List(msg, ["|"], []);
            string item = llList2String(f, 0);
            string label = llList2String(f, 1);

            if (!seated_on(id, item))
            {
                if (!allowed(id)) return;
            }

            // A sequence label and a pose label share one namespace on the
            // wire; sequences are checked first because a sequence that
            // shares a pose's name should drive the sequence.
            integer before = llGetListLength(seq_steps);
            seq_start(item, label);
            if (llGetListLength(seq_steps) != before) return;
            if (seq_item != "")
            {
                if (llList2String(seq_steps, 0) == label) return;
            }

            seq_stop();
            integer idx = pose_by_label(item, label, seat_of(id, item));
            if (idx >= 0) start_pose(item, idx);
            return;
        }

        if (num == QSC_RESYNC)
        {
            string item = msg;
            if (item == "")
                item = llList2String(llParseString2List(
                    llLinksetDataRead("qs:i:0"), ["|"], []), 0);
            integer n = (integer)llLinksetDataRead("qs:s:count");
            integer i = 0;
            while (i < n)
            {
                list s = llParseString2List(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
                string cur = llLinksetDataRead("qs:cur:" + item + "/" + llList2String(s, 0));
                if (cur != "")
                {
                    integer idx = pose_by_label(item, cur, llList2String(s, 0));
                    if (idx >= 0) { start_pose(item, idx); i = n; }
                }
                ++i;
            }
            return;
        }

        if (num == AV_PLUGINREPLY)
        {
            // Bound to the existence of a reply, not its payload, exactly
            // as v1's sitB does.
            has_security = TRUE;
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            string v = llLinksetDataRead("qs:cfg:verbose");
            if (v != "") verbose = (integer)v;
            seq_stop();
            llMessageLinked(LINK_SET, AV_PLUGINPROBE, "", "");
            return;
        }
    }
}
