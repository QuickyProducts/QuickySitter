/*
 * [QS]core - QuickySitter v2 pose engine
 *
 * Singleton. It owns WHAT GETS PLAYED. [QS]seat owns WHO SITS WHERE.
 *
 * DROP-IN REPLACEMENT: reads the schema today's [QS]boot already writes
 * and speaks the existing 900xx wire. See qs2/STATUS.md stage 1.
 *
 * THE v1 ENTRY MODEL, which this is built on
 *
 *   qs:p:<ch>:<i>       "<name>|<type>|<anim>|<pos>|<rot>"   KeepNulls
 *   qs:cfg:slots:<ch>   entry count for that channel
 *
 * type is one of:
 *   P  pose, SLOT-LOCAL. Only this channel plays it. name carries a
 *      "P:" prefix.
 *   S  sync. Couples across channels BY NAME, and the name has no
 *      prefix, which is what makes the match work.
 *   T  submenu button ("T:" prefix), M  menu marker, B  button
 *      ("B:" prefix). All three belong to [QS]menu, not here.
 *
 * Every channel carries its OWN full list, menu tree included. There is
 * no shared pose table.
 *
 * COUPLING IS THE TOKEN, NOT THE NAME. This is the semantic that had to
 * be rebuilt rather than moved. v1 dispatches a P to `channel =
 * SCRIPT_CHANNEL` and an S to `channel = ""`, a broadcast every sitA
 * then resolves against its own list (sitB.lsl:933). So two same-named
 * P entries in different channels are INDEPENDENT poses that merely
 * share a label, and the "Lalou" notecard has three such pairs (Sit,
 * Phone call, Dance) including the default sit pose. Matching on the
 * name alone would hand seat 1 seat 0's pose.
 *
 * WHY IT NEVER ASKS WHO IS SITTING. Occupancy lives in LSD (qs:occ:<ch>),
 * written by seat. core reads it directly, which is what keeps the
 * core/seat split off the hot path: a pose start is resolve-then-one-
 * message, not a conversation.
 *
 * NO LISTENER, NO PERMISSIONS, NO CHANGED_LINK. Dialogs belong to menu,
 * permission and animation to seat, occupancy too.
 *
 * NOT BUILT YET, deliberately rather than forgotten:
 *   - SEQUENCE stepping
 *   - the keyframed-motion pause/resume around a pose change (KFM)
 *   - the HUD wire, which lives in [QS]menu
 * See qs2/STATUS.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.03";

integer QSS_SEATED  = 90413;
integer QSS_VACATED = 90411;

integer QSC_REQUEST = 90420;
integer QSC_APPLY   = 90421;
integer QSC_PLAYING = 90422;
integer QSC_RESYNC  = 90423;
integer QSC_ALLOWED = 90424;
integer QSC_MAYI    = 90425;

integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

// Stock AVsitter numbers.
integer AV_POSEPLAYED  = 90045;   // core -> all: what is playing
integer AV_PLUGINPROBE = 90201;   // core -> plugins: announce yourselves
integer AV_PLUGINREPLY = 90202;   // root-security -> core

integer has_security;
integer SEATS;                    // channel count
integer DFLT;
integer SET;

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// v1 key shape, unchanged: the address is the slot integer.
string qso_key(key av, integer seat, string label)
{
    return "QSO:" + llGetSubString((string)av, 0, 7) + ":" + (string)seat
         + ":" + label;
}

// ------------------------------------------------------------- access

// Same shape as v1's adjust_allowed() (sitB.lsl:626): the owner always
// passes, otherwise the level comes from [QS]root-security via
// qs:sec:adjust. has_security is bound to the EXISTENCE of a 90202
// reply, not to its payload, exactly as sitB binds it.
integer allowed(key av)
{
    if (av == llGetOwner()) return TRUE;
    if (!has_security) return FALSE;
    string mode = llLinksetDataRead("qs:sec:adjust");
    if (mode == "ALL") return TRUE;
    if (mode == "GROUP") return llSameGroup(av);
    return FALSE;
}

// Sitting is itself the permission; the gate above is for people who
// are not sitting.
integer seated_anywhere(key av)
{
    integer i = 0;
    while (i < SEATS)
    {
        if (llLinksetDataRead("qs:occ:" + (string)i) == (string)av) return TRUE;
        ++i;
    }
    return FALSE;
}

// ------------------------------------------------------------- entries

list entry(integer ch, integer i)
{
    string v = llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i);
    if (v == "") return [];
    return llParseStringKeepNulls(v, ["|"], []);
}

// T:/P:/B: carry a two-character prefix; S does not, which is exactly
// why a SYNC name matches across channels unmodified.
string bare_name(string name)
{
    if (llListFindList(["T:", "P:", "B:"], [llGetSubString(name, 0, 1)]) == -1)
        return name;
    return llGetSubString(name, 2, 99999);
}

// Find the entry in this channel whose name matches, for the SYNC
// broadcast. Compares the raw field, since S entries are unprefixed.
integer find_by_name(integer ch, string name)
{
    integer n = (integer)llLinksetDataRead("qs:cfg:slots:" + (string)ch);
    integer i = 0;
    while (i < n)
    {
        list e = entry(ch, i);
        if (llList2String(e, 0) == name)
        {
            string t = llList2String(e, 1);
            if (t == "S") return i;
            if (t == "P") return i;
        }
        ++i;
    }
    return -1;
}

// -------------------------------------------------------------- offsets

// Default from the entry itself (fields 3 and 4), plus the seated user's
// personal offset if they saved one. Both are plain LSD reads, which is
// why this stays here rather than moving to the offset plugin with the
// editing UI: a wire round trip would make the pose visibly jump into
// place.
list resolve_offset(integer seat, list e, string label)
{
    vector pos = (vector)llList2String(e, 3);
    vector rot = (vector)llList2String(e, 4);

    key av = (key)llLinksetDataRead("qs:occ:" + (string)seat);
    if (av != "")
    {
        string pers = llLinksetDataRead(qso_key(av, seat, label));
        // M#T! is the reserved "same offset for every pose" entry, kept
        // from v1 unchanged.
        if (pers == "") pers = llLinksetDataRead(qso_key(av, seat, "M#T!"));
        if (pers != "")
        {
            list p = llParseString2List(pers, ["|"], []);
            pos += (vector)llList2String(p, 0);
            rot += (vector)llList2String(p, 1);
        }
    }
    return [pos, rot];
}

// -------------------------------------------------------------- camera

apply_camera(integer seat)
{
    // v1 drives the camera over 90202 in the plugin direction. Not wired
    // here yet; the entry model carries no camera field, it comes from
    // the notecard's CAMERA handling in [AV]camera.
}

// ----------------------------------------------------------- pose start

// Build one QSC_APPLY row.
string row_for(integer seat, list e, string label)
{
    list o = resolve_offset(seat, e, label);
    return (string)seat + "=" + llList2String(e, 2)
         + "=" + (string)llList2Vector(o, 0)
         + "=" + (string)llList2Vector(o, 1);
}

// Play entry <i> of channel <ch>, and everything it couples to.
start_entry(integer ch, integer i)
{
    list e = entry(ch, i);
    if (llGetListLength(e) == 0) return;

    string name  = llList2String(e, 0);
    string etype = llList2String(e, 1);
    string label = bare_name(name);

    string payload = row_for(ch, e, label);
    llLinksetDataWrite("qs:cur:" + (string)ch, label);
    string sitters = llLinksetDataRead("qs:occ:" + (string)ch);

    if (etype == "S")
    {
        // The broadcast. Every OTHER occupied channel looks for an entry
        // of its own with this name and plays that one. A channel that
        // has no such entry is simply not touched, which is how v1
        // scopes a SYNC without any grouping token.
        integer c = 0;
        while (c < SEATS)
        {
            if (c != ch)
            {
                if (llLinksetDataRead("qs:occ:" + (string)c) != "")
                {
                    integer at = find_by_name(c, name);
                    if (at >= 0)
                    {
                        list e2 = entry(c, at);
                        payload += "|" + row_for(c, e2, label);
                        llLinksetDataWrite("qs:cur:" + (string)c, label);
                        sitters += "@" + llLinksetDataRead("qs:occ:" + (string)c);
                    }
                }
            }
            ++c;
        }
    }

    llMessageLinked(LINK_SET, QSC_APPLY, payload, "");
    llMessageLinked(LINK_SET, QSC_PLAYING, (string)ch + "|" + label, "");

    // Stock pose-played broadcast, field order from sitA.lsl:571.
    integer isSync = 0;
    if (etype == "S") isSync = 1;
    llMessageLinked(LINK_SET, AV_POSEPLAYED,
        llDumpList2String([ch, label, "", SET, sitters, 0, isSync], "|"),
        (key)llLinksetDataRead("qs:occ:" + (string)ch));

    Out(2, "play ch" + (string)ch + " " + label + " type=" + etype);
}

// First playable entry of a channel, for a fresh occupant.
start_default(integer ch)
{
    integer n = (integer)llLinksetDataRead("qs:cfg:slots:" + (string)ch);
    integer i = 0;
    while (i < n)
    {
        string t = llList2String(entry(ch, i), 1);
        if (t == "P" || t == "S") { start_entry(ch, i); return; }
        ++i;
    }
}

load_cfg()
{
    string v = llLinksetDataRead("qs:cfg:verbose");
    if (v != "") verbose = (integer)v;

    list cfg = llParseStringKeepNulls(llLinksetDataRead("qs:cfg:0"), ["\n"], []);
    SET  = (integer)llList2String(cfg, 2);
    DFLT = (integer)llList2String(cfg, 10);

    SEATS = 0;
    while (llLinksetDataRead("qs:sitter:" + (string)SEATS) != "") ++SEATS;
}

default
{
    state_entry()
    {
        load_cfg();
        has_security = FALSE;
        // Same handshake v1 uses: ask, and treat any reply as proof that
        // [QS]root-security exists.
        llMessageLinked(LINK_SET, AV_PLUGINPROBE, "", "");
        Out(1, "ready, seats=" + (string)SEATS
            + " mem=" + (string)llGetFreeMemory());
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSS_SEATED)
        {
            start_default((integer)msg);
            return;
        }

        if (num == QSC_REQUEST)
        {
            // msg = "<seat>|<entryIndex>". menu sends the index rather
            // than a label precisely because a label is not unique.
            list f = llParseString2List(msg, ["|"], []);
            integer ch = (integer)llList2String(f, 0);
            if (!seated_anywhere(id))
            {
                if (!allowed(id)) return;
            }
            start_entry(ch, (integer)llList2String(f, 1));
            return;
        }

        if (num == QSC_MAYI)
        {
            integer ok = FALSE;
            if (seated_anywhere(id)) ok = TRUE;
            else ok = allowed(id);
            llMessageLinked(LINK_SET, QSC_ALLOWED, msg + "|" + (string)ok, id);
            return;
        }

        if (num == QSC_RESYNC)
        {
            // Re-apply whatever each occupied seat is currently playing.
            // Driving it from seat 0 outward means a SYNC re-couples the
            // others as a side effect rather than being applied twice.
            integer c = 0;
            while (c < SEATS)
            {
                string cur = llLinksetDataRead("qs:cur:" + (string)c);
                if (cur != "")
                {
                    if (llLinksetDataRead("qs:occ:" + (string)c) != "")
                    {
                        integer at = find_by_name(c, cur);
                        if (at == -1) at = find_by_name(c, "P:" + cur);
                        if (at >= 0) { start_entry(c, at); return; }
                    }
                }
                ++c;
            }
            return;
        }

        if (num == AV_PLUGINREPLY)
        {
            has_security = TRUE;
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            load_cfg();
            llMessageLinked(LINK_SET, AV_PLUGINPROBE, "", "");
            return;
        }
    }
}
