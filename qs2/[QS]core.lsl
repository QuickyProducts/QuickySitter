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
 *   - camera, which v1 drives from the notecard through [AV]camera
 * See qs2/STATUS.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.11";

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
integer AV_ANIMINFO    = 90055;   // core -> HUD/adjuster: per-seat pose info
integer AV_PLUGINPROBE = 90201;   // core -> plugins: announce yourselves
integer AV_PLUGINREPLY = 90202;   // root-security -> core

// QuickySitter presence. The project's documented way to detect a sitter
// and read its version; hudadmin forwards the version to the updater.
// In v1 only slot-0 sitA answered so that a probe got exactly one reply;
// a singleton has that for free.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;

integer AV_RESYNC     = 90271;    // hudproxy or any in-prim source
integer AV_POSESAVED  = 90301;    // adjuster -> here, after a [SAVE]

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

// "<product>|<version>|<sitterCount>|<capabilityCSV>", parsed by the
// receiver with llParseString2List; KeepNulls would re-introduce the
// trailing-empty bug.
//
// The capability list is deliberately SHORTER than v1.s. v1 advertises
// "customs90260,dump90098,offsetlsd_v1"; v2 reads the QSO offset store
// but implements neither the 90260 personal-offset wire nor the DUMP
// probe yet, and claiming a capability that is absent is worse than
// lacking it.
alive_reply()
{
    llMessageLinked(LINK_SET, QSALIVE_REPLY,
        "QuickySitter|" + version + "|" + (string)SEATS + "|"
        + "offsetlsd_v1", "");
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
list resolve_offset(integer seat, list e)
{
    vector pos = (vector)llList2String(e, 3);
    vector rot = (vector)llList2String(e, 4);

    key av = (key)llLinksetDataRead("qs:occ:" + (string)seat);
    if (av != "")
    {
        // KEYED ON THE RAW NAME, PREFIX INCLUDED. This took the bare
        // label, and the whole personal-offset store is keyed on the raw
        // one: [QS]offset writes the pose name through verbatim as it
        // arrives on 90262 (offset.lsl:138), the HUD sends it raw, and v1
        // looks it up with CURRENT_POSE_NAME, which is field 0 of the
        // stored entry (sitA.lsl:539). So a "P:Sit" entry was saved under
        // QSO:<short>:<slot>:P:Sit and looked up as ...:Sit, and never
        // found. Sitting down landed on the plain default, and only the
        // first HUD press moved anything, because that path takes its
        // position from the HUD's own cache instead of from here.
        string pers = llLinksetDataRead(qso_key(av, seat, llList2String(e, 0)));
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
// The label is no longer a parameter: both the animation and the
// offset key come out of the entry itself, and for a SYNC each
// participating seat has its OWN entry with its own raw name.
string row_for(integer seat, list e)
{
    list o = resolve_offset(seat, e);
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

    string payload = row_for(ch, e);
    llLinksetDataWrite("qs:cur:" + (string)ch, label);
    string sitters = llLinksetDataRead("qs:occ:" + (string)ch);

    // Strided 5: seat, rawName, anim, rawPos, rawRot. See the AV_ANIMINFO
    // block below for why this is not derived from `payload`.
    list infos = [ch, name, llList2String(e, 2),
                  llList2String(e, 3), llList2String(e, 4)];

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
                integer at = find_by_name(c, name);
                if (at >= 0)
                {
                    // qs:cur is written for EMPTY channels too, and that
                    // is the couple-join mechanism, not bookkeeping: in
                    // v1 the empty seat's sitA follows the SYNC broadcast
                    // and remembers it as CURRENT, so whoever sits down
                    // there next starts INTO the couple pose instead of
                    // their solo default (sitA.lsl:1587, the grant path
                    // plays CURRENT whatever it is). start_default reads
                    // this back.
                    llLinksetDataWrite("qs:cur:" + (string)c, label);
                    if (llLinksetDataRead("qs:occ:" + (string)c) != "")
                    {
                        list e2 = entry(c, at);
                        payload += "|" + row_for(c, e2);
                        infos += [c, llList2String(e2, 0), llList2String(e2, 2),
                                  llList2String(e2, 3), llList2String(e2, 4)];
                        sitters += "@" + llLinksetDataRead("qs:occ:" + (string)c);
                    }
                }
            }
            ++c;
        }
    }

    llMessageLinked(LINK_SET, QSC_APPLY, payload, "");
    llMessageLinked(LINK_SET, QSC_PLAYING, (string)ch + "|" + label, "");

    // AV_ANIMINFO per seat. This is not decoration: hudproxy CACHES the
    // pose name and its pos/rot from 90055 and derives the absolute
    // target of an adjust arrow from that cache (hudproxy.lsl:1177 ->
    // applyPoseChange). With no 90055 the cache stays empty and every
    // arrow press on the HUD computes an offset against nothing, so the
    // avatar does not move at all. The v1 adjuster reads it too.
    //
    // Emitting one per participating seat rather than once for <ch> is
    // what keeps a SYNC correct: all coupled seats moved, so all of them
    // need their entry refreshed, not just the one that was clicked.
    //
    // IT CARRIES THE RAW ENTRY, NOT THE RESOLVED ONE, which is the whole
    // reason `infos` exists next to `payload` instead of being parsed
    // back out of it. Two receivers depend on raw:
    //
    //   - hudproxy adds the stored personal offset to the cached value
    //     itself (hudproxy.lsl:713). Feeding it the already-resolved
    //     position applies that offset twice.
    //   - the adjuster's ADJUSTMODE path writes the value straight back
    //     into qs:p:<ch>:<i> as the new pose default (adjuster.lsl:891).
    //     With a resolved value that compounds one sitter's personal
    //     offset into the notecard default on every pose start.
    //
    // The name is raw too, prefix included: qs_find_index() and
    // hudproxy's cache both key on the stored name, and a stripped label
    // silently matches nothing.
    //
    // Field order and the per-seat str are v1's (sitB.lsl:223). The two
    // trailing fields are broadcast and speed_index, neither of which v2
    // drives yet, and neither receiver reads them.
    integer r = 0;
    integer rows = llGetListLength(infos);
    while (r < rows)
    {
        llMessageLinked(LINK_THIS, AV_ANIMINFO, llList2String(infos, r),
            llDumpList2String([llList2String(infos, r + 1),
                llList2String(infos, r + 2), llList2String(infos, r + 3),
                llList2String(infos, r + 4), 0, 0], "|"));
        r += 5;
    }

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
    // What this channel is REMEMBERED to be playing wins over the
    // notecard default. That is v1's behaviour, not an addition: the
    // grant path plays CURRENT_POSE_NAME unconditionally, and CURRENT
    // survives on a seat until the whole furniture empties. It is what
    // makes the second sitter join a couple pose the first one already
    // chose, and what puts somebody who stood up briefly back where
    // they were.
    string cur = llLinksetDataRead("qs:cur:" + (string)ch);
    if (cur != "")
    {
        integer at = find_by_name(ch, cur);
        if (at == -1) at = find_by_name(ch, "P:" + cur);
        if (at >= 0) { start_entry(ch, at); return; }
    }

    integer n = (integer)llLinksetDataRead("qs:cfg:slots:" + (string)ch);
    integer i = 0;
    while (i < n)
    {
        string t = llList2String(entry(ch, i), 1);
        if (t == "P" || t == "S") { start_entry(ch, i); return; }
        ++i;
    }
    // Loud, because the symptom - a sitter who is simply not animated -
    // says nothing about whether the channel has no poses, or has none
    // yet because boot has not finished, or was never seeded at all.
    Out(0, "seat " + (string)ch + " has no playable pose among "
        + (string)n + " entries - nobody will be animated there.");
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
        // ANNOUNCE, do not only answer. hudadmin probes at ITS state_entry
        // and sizes its SITTERS list from the count in our reply; if we
        // started later, or were reset, that probe went unanswered and it
        // is left believing there is one seat. Whoever starts last has to
        // speak up.
        alive_reply();
        Out(1, "ready, seats=" + (string)SEATS
            + " mem=" + (string)llGetFreeMemory());
    }

    // v1.s boot signals nothing when it finishes: it writes qs:meta:<ch>
    // and the sitters poll for it (boot.lsl comment at finalize_boot). We
    // waited for a v2-only 90430 that nobody sends, so a script that
    // started before boot finished stayed empty forever and only a manual
    // reset fixed it. Watching the key is event-driven, so no timer.
    linkset_data(integer act, string name, string val)
    {
        if (name == "qs:meta:0" || name == "qs:cfg:verbose" || act == LINKSETDATA_RESET)
        {
            load_cfg();
            alive_reply();
        }
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSS_SEATED)
        {
            start_default((integer)msg);
            return;
        }

        if (num == QSS_VACATED)
        {
            // v1's reset point: a seat's remembered pose survives every
            // individual stand-up and dies only when the whole furniture
            // empties, gated on DFLT (sitA.lsl:1497). Without the
            // survive-part a brief stand-up loses the couple pose;
            // without the reset-part the furniture greets the next
            // couple with whatever the last one was doing.
            integer c = 0;
            while (c < SEATS)
            {
                if (llLinksetDataRead("qs:occ:" + (string)c) != "") return;
                ++c;
            }
            if (DFLT) llLinksetDataDeleteFound("^qs:cur:", "");
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

        if (num == QSALIVE_PROBE)
        {
            alive_reply();
            return;
        }

        if (num == AV_RESYNC)
        {
            // Stop and restart what is playing, so a couple pose that has
            // drifted comes back into phase. Re-applying the pose does
            // exactly that and re-resolves the offsets while it is at it.
            llMessageLinked(LINK_SET, QSC_RESYNC, "", "");
            return;
        }

        if (num == AV_POSESAVED)
        {
            // THE SLOT IS IN msg, THE PAYLOAD IS IN id:
            // msg = "<slot>", id = "<name>|<pos>|<rot>|". Reading the
            // payload out of msg, which is what this did, meant the name
            // was always a slot number and 90301 never resolved to
            // anything. This path has never worked in v2.
            //
            // Two senders, identical shape: the adjuster's [SAVE]
            // (adjuster.lsl:748), and QuickyHUD's adjust arrows while
            // ADJUSTMODE is On (hudproxy.lsl:671). The HUD sender is why
            // this cannot re-read qs:p the way a [SAVE] alone could: at
            // this moment NOTHING has written the new position yet. The
            // adjuster persists it only when it sees the AV_ANIMINFO we
            // send below, so the payload is the only copy in existence
            // and has to be applied straight from here.
            integer c = (integer)msg;
            if (c < 0) return;
            if (c >= SEATS) return;
            list f = llParseString2List((string)id, ["|"], []);
            string nm = llList2String(f, 0);

            // v1's rule (sitB.lsl:1748): act only when the saved pose is
            // the one this seat is playing. Otherwise there is nothing
            // visible to update and the new default takes effect on the
            // next sit. qs:cur holds the bare label; the payload name may
            // carry a "P:" prefix.
            if (llLinksetDataRead("qs:cur:" + (string)c) != bare_name(nm))
                return;

            integer at = find_by_name(c, nm);
            if (at == -1) at = find_by_name(c, "P:" + nm);
            if (at == -1) return;
            string anim = llList2String(entry(c, at), 2);

            // Adjuster and HUD first. With ADJUSTMODE On the adjuster
            // turns this into the qs:p write that makes the edit
            // permanent, and hudproxy re-caches so the NEXT arrow press
            // builds on the new value rather than repeating the old one.
            llMessageLinked(LINK_THIS, AV_ANIMINFO, (string)c,
                llDumpList2String([nm, anim, llList2String(f, 1),
                    llList2String(f, 2), 0, 0], "|"));

            // Then move, with the explicit values rather than a re-read.
            // seat only restarts an animation when the name changes, so
            // an unchanged anim here means it just re-places the sit
            // target, which is exactly the intent.
            llMessageLinked(LINK_SET, QSC_APPLY,
                (string)c + "=" + anim + "=" + llList2String(f, 1)
                + "=" + llList2String(f, 2), "");
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
