/*
 * [QS]menu - QuickySitter v2 dialogs
 *
 * Singleton. Renders menus, dispatches clicks, and holds the entry
 * registry. It is the only v2 script with a listener.
 *
 * IT KNOWS NOTHING ABOUT AUTHORING
 *
 * There is no "[HELPER]", "[QUICKYHUD]", "[NEW]", "[SAVE]" or "[DUMP]"
 * literal anywhere in this file. Every entry that is not a notecard pose
 * is registered at runtime by the script that owns it, and disappears
 * when that script is removed. That is what makes /5 cleanup a real
 * removal instead of a hidden state. See qs2/REGISTRY.md.
 *
 * PER-OPERATOR STATE
 *
 * Every sitB instance served exactly one operator, so its dialog state
 * could be globals. A singleton serves several at once: two people on a
 * bed browsing, plus an owner touching the furniture. Each gets a row in
 * OPS. See DESIGN.md §6.6 for why a shared listen channel was rejected —
 * in short, a dialog cannot be closed, and a per-dialog random channel is
 * what makes a click on a stale window land nowhere instead of being
 * executed against current state.
 *
 * MENU DATA IN LSD (written by [QS]boot)
 *
 *   qs:m:<item>:count      number of menu nodes
 *   qs:m:<item>:<n>        "<path>|<flags>"   flags: h = hidden, no button
 *   qs:pm:<item>:<n>       menu path of pose n ("" = top level)
 *   qs:p:<item>:<n>        pose row, see [QS]core
 *
 * NOT BUILT YET, deliberately:
 *   - the seat picker and the swap dialog
 *   - [OPTIONS] paging beyond the flat case
 *
 * Wire: see qs2/PROTOCOL.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.01";

integer QSS_TOUCH    = 90412;
integer QSC_REQUEST  = 90420;
integer QS_REGISTER   = 90212;
integer QS_UNREGISTER = 90216;

integer QSB_READY   = 90430;
integer QSB_RELOAD  = 90431;

// OPS strided 8: avatar, channel, handle, item, path, page, navCSV, lastAct
// navCSV is a string because LSL lists cannot nest. page_map is NOT stored:
// it is re-derived on click from (path, page), which costs one pass and
// removes the nesting problem with it.
list OPS;
integer OPS_STRIDE = 8;
integer OPS_CAP = 6;

// REG strided 5: label, path, channel, owner, flags
list REG;
integer REG_STRIDE = 5;

integer PAGE = 9;          // entries per dialog page, leaving room for nav
integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// ------------------------------------------------------------ operators

integer op_of_channel(integer chan)
{
    integer i = 0;
    integer n = llGetListLength(OPS);
    while (i < n)
    {
        if (llList2Integer(OPS, i + 1) == chan) return i / OPS_STRIDE;
        i += OPS_STRIDE;
    }
    return -1;
}

integer op_of_avatar(key av)
{
    integer i = 0;
    integer n = llGetListLength(OPS);
    while (i < n)
    {
        if (llList2String(OPS, i) == (string)av) return i / OPS_STRIDE;
        i += OPS_STRIDE;
    }
    return -1;
}

op_drop(integer op)
{
    if (op < 0) return;
    integer row = op * OPS_STRIDE;
    llListenRemove(llList2Integer(OPS, row + 2));
    OPS = llDeleteSubList(OPS, row, row + OPS_STRIDE - 1);
    if (llGetListLength(OPS) == 0) llSetTimerEvent(0.0);
}

// Evict the least recently active. Every row holds a listen, so the cap
// is not cosmetic.
op_evict_oldest()
{
    integer i = 0;
    integer n = llGetListLength(OPS);
    integer oldest = 0;
    integer best = 0x7FFFFFFF;
    while (i < n)
    {
        integer t = llList2Integer(OPS, i + 7);
        if (t < best) { best = t; oldest = i / OPS_STRIDE; }
        i += OPS_STRIDE;
    }
    op_drop(oldest);
}

integer op_open(key av, string item)
{
    integer op = op_of_avatar(av);
    if (op >= 0) op_drop(op);                  // re-open: fresh channel
    if (llGetListLength(OPS) / OPS_STRIDE >= OPS_CAP) op_evict_oldest();

    integer chan = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    integer h = llListen(chan, "", av, "");
    OPS += [(string)av, chan, h, item, "", 0, "", llGetUnixTime()];
    // Armed only while somebody has a dialog open, disarmed when the last
    // one drains. There is no event for "the operator walked away", so a
    // sweep is the one place the event-driven preference cannot hold.
    llSetTimerEvent(60.0);
    return llGetListLength(OPS) / OPS_STRIDE - 1;
}

// ------------------------------------------------------------- registry

integer reg_find(string owner)
{
    integer i = 0;
    integer n = llGetListLength(REG);
    while (i < n)
    {
        if (llList2String(REG, i + 3) == owner) return i / REG_STRIDE;
        i += REG_STRIDE;
    }
    return -1;
}

reg_drop_owner(string owner)
{
    integer i = llGetListLength(REG);
    while (i > 0)
    {
        i -= REG_STRIDE;
        if (llList2String(REG, i + 3) == owner)
            REG = llDeleteSubList(REG, i, i + REG_STRIDE - 1);
    }
}

// ------------------------------------------------------------ rendering

// Does this pose offer itself to this operator? Visibility is derived
// from participation: a pose is offered to a seat if and only if that
// seat appears in the pose line. A non-seated operator (an owner
// touching the furniture) sees everything.
integer pose_visible(string row, string seatName)
{
    if (seatName == "") return TRUE;
    list f = llParseString2List(row, ["|"], []);
    integer i = 1;
    integer n = llGetListLength(f);
    while (i < n)
    {
        string pair = llList2String(f, i);
        integer cut = llSubStringIndex(pair, "=");
        if (cut > 0)
        {
            if (llGetSubString(pair, 0, cut - 1) == seatName) return TRUE;
        }
        ++i;
    }
    return FALSE;
}

string seat_of_avatar(string item, key av)
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

// Build the full entry list for one menu node, in the documented order:
// notecard entries first, then registered entries in registration order.
// Child menus come before poses so navigation stays at the top.
list build_entries(string item, string path, key av)
{
    string seatName = seat_of_avatar(item, av);
    list out;

    integer mn = (integer)llLinksetDataRead("qs:m:" + item + ":count");
    integer i = 0;
    while (i < mn)
    {
        list m = llParseString2List(llLinksetDataRead("qs:m:" + item + ":" + (string)i), ["|"], []);
        string mp = llList2String(m, 0);
        if (llSubStringIndex(llList2String(m, 1), "h") == -1)
        {
            // Direct child of the current path?
            string prefix = path;
            if (prefix != "") prefix += "/";
            if (llSubStringIndex(mp, prefix) == 0)
            {
                string tail = llGetSubString(mp, llStringLength(prefix), -1);
                if (tail != "")
                {
                    if (llSubStringIndex(tail, "/") == -1) out += ["M" + mp];
                }
            }
        }
        ++i;
    }

    integer pn = (integer)llLinksetDataRead("qs:p:" + item + ":count");
    i = 0;
    while (i < pn)
    {
        if (llLinksetDataRead("qs:pm:" + item + ":" + (string)i) == path)
        {
            string row = llLinksetDataRead("qs:p:" + item + ":" + (string)i);
            if (pose_visible(row, seatName))
                out += ["P" + llList2String(llParseString2List(row, ["|"], []), 0)];
        }
        ++i;
    }

    integer rn = llGetListLength(REG);
    i = 0;
    while (i < rn)
    {
        if (llList2String(REG, i + 1) == path)
        {
            integer flags = llList2Integer(REG, i + 4);
            integer show = TRUE;
            if (flags & 1)
            {
                if (av != llGetOwner()) show = FALSE;
            }
            if (show) out += ["R" + llList2String(REG, i)];
        }
        i += REG_STRIDE;
    }
    return out;
}

render(integer op)
{
    if (op < 0) return;
    integer row = op * OPS_STRIDE;
    key av      = (key)llList2String(OPS, row);
    string item = llList2String(OPS, row + 3);
    string path = llList2String(OPS, row + 4);
    integer page = llList2Integer(OPS, row + 5);

    list all = build_entries(item, path, av);
    integer total = llGetListLength(all);
    integer pages = (total + PAGE - 1) / PAGE;
    if (pages < 1) pages = 1;
    if (page >= pages) page = 0;

    list btns;
    integer i = page * PAGE;
    integer stop = i + PAGE;
    if (stop > total) stop = total;
    while (i < stop)
    {
        string e = llList2String(all, i);
        string label = llGetSubString(e, 1, -1);
        if (llGetSubString(e, 0, 0) == "M")
        {
            // Show only the leaf name on the button, not the whole path.
            integer c = llSubStringIndex(label, "/");
            while (c != -1)
            {
                label = llGetSubString(label, c + 1, -1);
                c = llSubStringIndex(label, "/");
            }
            label = label + " >";
        }
        btns += label;
        ++i;
    }

    if (path != "") btns += "[BACK]";
    if (pages > 1) btns += ["[<<]", "[>>]"];

    OPS = llListReplaceList(OPS, [page, llGetUnixTime()], row + 5, row + 5);
    OPS = llListReplaceList(OPS, [llGetUnixTime()], row + 7, row + 7);

    string title = "\n" + item;
    if (path != "") title += " — " + path;
    llDialog(av, title, btns, llList2Integer(OPS, row + 1));
}

// ------------------------------------------------------------- dispatch

click(integer op, string msg)
{
    integer row = op * OPS_STRIDE;
    key av      = (key)llList2String(OPS, row);
    string item = llList2String(OPS, row + 3);
    string path = llList2String(OPS, row + 4);
    integer page = llList2Integer(OPS, row + 5);

    if (msg == "[>>]") { OPS = llListReplaceList(OPS, [page + 1], row + 5, row + 5); render(op); return; }
    if (msg == "[<<]")
    {
        integer p = page - 1;
        if (p < 0) p = 0;
        OPS = llListReplaceList(OPS, [p], row + 5, row + 5);
        render(op);
        return;
    }
    if (msg == "[BACK]")
    {
        string nav = llList2String(OPS, row + 6);
        string back = "";
        integer cut = llSubStringIndex(path, "/");
        // Parent path is everything before the last "/".
        integer last = -1;
        integer i = 0;
        while (i < llStringLength(path))
        {
            if (llGetSubString(path, i, i) == "/") last = i;
            ++i;
        }
        if (last > 0) back = llGetSubString(path, 0, last - 1);
        OPS = llListReplaceList(OPS, [back, 0], row + 4, row + 5);
        render(op);
        return;
    }

    // Re-derive the page contents rather than caching them per operator.
    list all = build_entries(item, path, av);
    integer i2 = 0;
    integer n = llGetListLength(all);
    while (i2 < n)
    {
        string e = llList2String(all, i2);
        string kind = llGetSubString(e, 0, 0);
        string label = llGetSubString(e, 1, -1);

        if (kind == "M")
        {
            string leaf = label;
            integer c = llSubStringIndex(leaf, "/");
            while (c != -1)
            {
                leaf = llGetSubString(leaf, c + 1, -1);
                c = llSubStringIndex(leaf, "/");
            }
            if (leaf + " >" == msg)
            {
                OPS = llListReplaceList(OPS, [label, 0], row + 4, row + 5);
                render(op);
                return;
            }
        }
        else
        {
            if (label == msg)
            {
                if (kind == "P")
                {
                    llMessageLinked(LINK_SET, QSC_REQUEST, item + "|" + label, av);
                }
                else
                {
                    // Registered entry: fire its channel with the label,
                    // exactly as sitB does today, so plugin click handlers
                    // need no change.
                    integer r = 0;
                    integer rn = llGetListLength(REG);
                    while (r < rn)
                    {
                        if (llList2String(REG, r) == label)
                        {
                            llMessageLinked(LINK_SET, llList2Integer(REG, r + 2), label, av);
                            r = rn;
                        }
                        r += REG_STRIDE;
                    }
                }
                render(op);
                return;
            }
        }
        ++i2;
    }
    // Unknown label: the page moved under the operator. Re-render.
    render(op);
}

default
{
    state_entry()
    {
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        Out(1, "ready, mem=" + (string)llGetFreeMemory());
    }

    timer()
    {
        // Sweep operators who walked away. A dialog cannot be closed, so
        // nothing else will ever tell us.
        integer now = llGetUnixTime();
        integer i = llGetListLength(OPS);
        while (i > 0)
        {
            i -= OPS_STRIDE;
            if (now - llList2Integer(OPS, i + 7) > 300) op_drop(i / OPS_STRIDE);
        }
        if (llGetListLength(OPS) == 0) llSetTimerEvent(0.0);
    }

    listen(integer chan, string name, key id, string msg)
    {
        integer op = op_of_channel(chan);
        if (op < 0) return;
        if (llList2String(OPS, op * OPS_STRIDE) != (string)id) return;
        click(op, msg);
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSS_TOUCH)
        {
            render(op_open(id, msg));
            return;
        }

        if (num == QS_REGISTER)
        {
            // "<label>|<channel>|<owner>|<flags>|<path>". A 3-field
            // payload is a v1 QSPLUG_REGISTER and defaults to [OPTIONS];
            // see REGISTRY.md §3.
            list f = llParseString2List(msg, ["|"], []);
            string label = llList2String(f, 0);
            integer chan = llList2Integer(f, 1);
            string owner = llList2String(f, 2);
            if (label == "") return;
            if (chan == 0) return;
            if (owner == "") return;
            integer flags = 0;
            string path = "[OPTIONS]";
            if (llGetListLength(f) > 3) flags = llList2Integer(f, 3);
            if (llGetListLength(f) > 4) path  = llList2String(f, 4);

            integer at = reg_find(owner);
            if (at >= 0) REG = llDeleteSubList(REG, at * REG_STRIDE, at * REG_STRIDE + REG_STRIDE - 1);
            REG += [label, path, chan, owner, flags];
            return;
        }

        if (num == QS_UNREGISTER)
        {
            reg_drop_owner((string)id);
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
