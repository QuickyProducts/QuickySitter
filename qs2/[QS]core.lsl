/*
 * [QS]core - QuickySitter v2 pose engine
 *
 * Singleton. It owns WHAT GETS PLAYED. [QS]seat owns WHO SITS WHERE.
 *
 * Responsibilities: the pose model, resolving a pose into per-seat
 * animations and positions, applying default and personal offsets,
 * camera, and the plugin/HUD broadcast.
 *
 * WHY IT NEVER ASKS WHO IS SITTING
 *
 * Occupancy lives in LSD (qs:occ:*), written by [QS]seat. core reads it
 * directly. That is what keeps the core/seat split off the hot path: a
 * pose start is resolve-then-one-message, not a conversation. See
 * qs2/DESIGN.md §2.
 *
 * NO LISTENER, NO PERMISSIONS, NO CHANGED_LINK. Dialogs belong to
 * [QS]menu, permission to [QS]anim, occupancy to [QS]seat. Losing the
 * dialog apparatus is what removes the orphaned-listener failure class
 * from the engine entirely.
 *
 * POSE DATA IN LSD (written by [QS]boot)
 *
 *   qs:p:<item>:count        number of poses in this item
 *   qs:p:<item>:<n>          "<label>|<seat>=<anim>|<seat>=<anim>|…"
 *   qs:o:<item>:<n>:<seat>   "<pos>|<rot>"   default offset, from POS lines
 *
 * Personal offsets keep the v1 shape with the v2 address:
 *   QSO:<short>:<item>/<seat>:<label>
 *
 * A pose names only the seats that take part. Whoever is not named is
 * not touched, and a named seat that happens to be empty is skipped.
 * That is the whole of what POSE-versus-SYNC used to encode.
 *
 * NOT BUILT YET, deliberately rather than forgotten:
 *   - SEQUENCE stepping (needs the timer path)
 *   - the root-security handoff for access gating
 *   - stock-compat emission of the legacy 900xx slot-integer messages
 *     (DESIGN.md §7.5), which belongs here once the shape is settled
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.01";

integer QSS_SEATED  = 90413;

integer QSC_REQUEST = 90420;
integer QSC_APPLY   = 90421;
integer QSC_PLAYING = 90422;
integer QSC_RESYNC  = 90423;

integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// Personal-offset key shape. Must stay in step with [QS]offset, which
// owns the QSO namespace; only the address part changes in v2, from
// <slot> to <item>/<seat>.
string qso_key(key av, string addr, string label)
{
    return "QSO:" + llGetSubString((string)av, 0, 7) + ":" + addr + ":" + label;
}

// Default offset from the notecard's POS line, plus the seated user's
// personal offset if they have saved one. Both are plain LSD reads, which
// is why this stays in core instead of moving to the offset plugin with
// the editing UI: a wire round trip here would make the pose visibly jump
// into place. See DESIGN.md §6.5.
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
        if (pers == "")
        {
            // M#T! is the reserved "same offset for every pose" entry,
            // carried over from v1 unchanged.
            pers = llLinksetDataRead(qso_key(av, addr, "M#T!"));
        }
        if (pers != "")
        {
            list p = llParseString2List(pers, ["|"], []);
            pos += (vector)llList2String(p, 0);
            rot += (vector)llList2String(p, 1);
        }
    }
    return [pos, rot];
}

integer pose_by_label(string item, string label)
{
    integer n = (integer)llLinksetDataRead("qs:p:" + item + ":count");
    integer i = 0;
    while (i < n)
    {
        string row = llLinksetDataRead("qs:p:" + item + ":" + (string)i);
        if (llList2String(llParseString2List(row, ["|"], []), 0) == label) return i;
        ++i;
    }
    return -1;
}

// Resolve a pose completely and hand [QS]seat one message. seat places
// the sit targets and fires a single QSA_PLAY broadcast, so every
// participating animator starts in the same sim frame.
start_pose(string item, integer idx)
{
    string row = llLinksetDataRead("qs:p:" + item + ":" + (string)idx);
    if (row == "") return;

    list f = llParseString2List(row, ["|"], []);
    string label = llList2String(f, 0);

    string payload = "";
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

            // A named but empty seat is skipped, not left in a half state.
            if (llLinksetDataRead("qs:occ:" + addr) != "")
            {
                list o = resolve_offset(item, idx, seatName, label);
                if (payload != "") payload += "|";
                payload += seatName + "=" + anim
                         + "=" + (string)llList2Vector(o, 0)
                         + "=" + (string)llList2Vector(o, 1);
                llLinksetDataWrite("qs:cur:" + addr, label);
            }
        }
        ++i;
    }

    if (payload == "") return;
    llMessageLinked(LINK_SET, QSC_APPLY, payload, item);
    llMessageLinked(LINK_SET, QSC_PLAYING, item + "|" + label, "");
    Out(2, "play " + item + " / " + label);
}

// Which pose does a fresh occupant get. Falls back to the first pose of
// the item, which is the v1 behaviour for a sitter with no active pose.
start_default(string item)
{
    if ((integer)llLinksetDataRead("qs:p:" + item + ":count") > 0)
        start_pose(item, 0);
}

default
{
    state_entry()
    {
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        Out(1, "ready, mem=" + (string)llGetFreeMemory());
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSS_SEATED)
        {
            // msg = "<item>/<seat>". Permission has landed by now; seat
            // does not send this until QSA_READY, because an earlier
            // QSA_PLAY would be dropped rather than queued.
            integer cut = llSubStringIndex(msg, "/");
            if (cut > 0) start_default(llGetSubString(msg, 0, cut - 1));
            return;
        }

        if (num == QSC_REQUEST)
        {
            // msg = "<item>|<label>" from [QS]menu.
            list f = llParseString2List(msg, ["|"], []);
            string item = llList2String(f, 0);
            integer idx = pose_by_label(item, llList2String(f, 1));
            if (idx >= 0) start_pose(item, idx);
            return;
        }

        if (num == QSC_RESYNC)
        {
            // Re-apply whatever is currently playing on this item. The
            // HUD's re-sync trigger lands here in v2.
            string item = msg;
            string first = llLinksetDataRead("qs:i:0");
            if (item == "") item = llList2String(llParseString2List(first, ["|"], []), 0);
            integer n = (integer)llLinksetDataRead("qs:s:count");
            integer i = 0;
            while (i < n)
            {
                list s = llParseString2List(llLinksetDataRead("qs:s:" + (string)i), ["|"], []);
                string cur = llLinksetDataRead("qs:cur:" + item + "/" + llList2String(s, 0));
                if (cur != "")
                {
                    integer idx = pose_by_label(item, cur);
                    if (idx >= 0) { start_pose(item, idx); i = n; }
                }
                ++i;
            }
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            string v = llLinksetDataRead("qs:cfg:verbose");
            if (v != "") verbose = (integer)v;
            return;
        }
    }
}
