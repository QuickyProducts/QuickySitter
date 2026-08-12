/*
 * [QS]menu - QuickySitter v2 dialogs
 *
 * Singleton. Renders menus, dispatches clicks, holds the entry registry.
 * The only v2 script with a listener.
 *
 * DROP-IN REPLACEMENT: reads the schema today's [QS]boot already writes.
 * See qs2/STATUS.md stage 1.
 *
 * THE v1 MENU MODEL
 *
 *   qs:p:<ch>:<i>       "<name>|<type>|<anim>|<pos>|<rot>"   KeepNulls
 *   qs:nm:<ch>:<mi>     child count of the section opened by marker <mi>
 *                       (mi = -1 is the root section)
 *   qs:nt:<ch>:<ti>     the M: index a T: at <ti> navigates to
 *   qs:cfg:slots:<ch>   entry count
 *
 * Entries are one flat list per channel. A section that starts at marker
 * <mi> owns the entries mi+1 … mi+count, contiguously. Nesting is NOT
 * containment: submenus sit side by side in the list and are reached by
 * following a T: through the qs:nt sidecar. That is why rendering a
 * section is a range walk and needs no tree.
 *
 * Types: P slot-local pose, S sync pose, T submenu button, M section
 * marker, B channel button. T:/P:/B: names carry a two-character prefix,
 * S does not.
 *
 * IT KNOWS NOTHING ABOUT AUTHORING. There is no "[HELPER]",
 * "[QUICKYHUD]", "[NEW]", "[SAVE]" or "[DUMP]" literal in this file.
 * Every entry that is not a notecard entry is registered at runtime by
 * the script that owns it and disappears when that script is removed,
 * which is what makes /5 cleanup a real removal. See qs2/REGISTRY.md.
 *
 * PER-OPERATOR STATE. Each sitB instance served exactly one operator, so
 * its dialog state could be globals. A singleton serves several at once:
 * two people on a bed browsing, plus an owner touching the furniture.
 * Each gets a row in OPS. The per-dialog random channel is deliberate,
 * not incidental: a dialog cannot be closed programmatically, so a click
 * on a stale window must land on a channel nobody listens to. On a
 * long-lived shared channel it would be executed against current state.
 * See DESIGN.md §6.6.
 *
 * IT SENDS core AN INDEX, NOT A LABEL. Two P entries in different
 * channels may share a name - the "Lalou" notecard has three such pairs
 * including the default sit pose - so a label does not identify a pose.
 *
 * NOT BUILT YET: the seat picker, the swap dialog, MTYPE/ETYPE click
 * modes. See qs2/STATUS.md.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.05";

integer QSS_TOUCH     = 90412;
integer AV_MENUTOUSER = 90005;   // stock "send menu to user"
integer AV_MENUCHOICE = 90100;   // back route: inject a menu click
integer AV_MENUNAV    = 90101;   // same, submenu navigation
integer QSC_REQUEST   = 90420;
// v1 registration wire, unchanged so plugins do not notice the receiver
// moving from sitB to here.
integer QSPLUG_REGISTER  = 90212;   // -> [OPTIONS]. No unregister exists.
integer QSADJ_REGISTER   = 90213;   // -> [ADJUST]
integer QSADJ_UNREGISTER = 90216;   // counterpart of 90213, msg = scriptName
integer QSB_READY     = 90430;
integer QSB_RELOAD    = 90431;

string SEP;                 // U+FFFD, the v1 intra-field separator

// OPS strided 8: avatar, seat, dialogChannel, listenHandle, section,
//                page, navCSV, lastAct
// navCSV is a string because LSL lists cannot nest. The rendered page is
// NOT stored: it is re-derived on click, which removes the nesting
// problem and costs one pass.
list OPS;
integer OPS_STRIDE = 8;
integer OPS_CAP = 6;

// REG strided 5: label, dest, channel, owner, flags
// dest is "O" for the [OPTIONS] submenu or "A" for [ADJUST].
list REG;
integer REG_STRIDE = 5;

// Synthetic section ids, chosen below -1 so they cannot collide with a
// real M: marker index (those are >= 0, and -1 is the root).
integer SEC_OPTIONS = -2;
integer SEC_ADJUST  = -3;

integer PAGE = 9;           // entries per dialog page, leaving room for nav
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
        if (llList2Integer(OPS, i + 2) == chan) return i / OPS_STRIDE;
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
    llListenRemove(llList2Integer(OPS, row + 3));
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

integer op_open(key av, integer ch)
{
    integer op = op_of_avatar(av);
    if (op >= 0) op_drop(op);                  // re-open: fresh channel
    if (llGetListLength(OPS) / OPS_STRIDE >= OPS_CAP) op_evict_oldest();

    integer chan = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    integer h = llListen(chan, "", av, "");
    OPS += [(string)av, ch, chan, h, -1, 0, "", llGetUnixTime()];
    // Armed only while somebody has a dialog open, disarmed when the
    // last one drains. There is no event for "the operator walked away",
    // so a sweep is the one place the event-driven preference cannot
    // hold.
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

// ------------------------------------------------------------- entries

list entry(integer ch, integer i)
{
    string v = llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i);
    if (v == "") return [];
    return llParseStringKeepNulls(v, ["|"], []);
}

string bare_name(string name)
{
    if (llListFindList(["T:", "P:", "B:"], [llGetSubString(name, 0, 1)]) == -1)
        return name;
    return llGetSubString(name, 2, 99999);
}

// A section starting at marker <mi> owns the entries mi+1 … mi+count.
// The root section is mi = -1, so its range starts at 0.
integer section_count(integer ch, integer mi)
{
    return (integer)llLinksetDataRead("qs:nm:" + (string)ch + ":" + (string)mi);
}

// Which seat is this avatar in? -1 when not seated.
integer seat_of(key av)
{
    integer c = 0;
    while (llLinksetDataRead("qs:sitter:" + (string)c) != "")
    {
        if (llLinksetDataRead("qs:occ:" + (string)c) == (string)av) return c;
        ++c;
    }
    return -1;
}

// ------------------------------------------------------------ rendering

render(integer op)
{
    if (op < 0) return;
    integer row = op * OPS_STRIDE;
    key av       = (key)llList2String(OPS, row);
    integer ch   = llList2Integer(OPS, row + 1);
    integer mi   = llList2Integer(OPS, row + 4);
    integer page = llList2Integer(OPS, row + 5);

    integer first = mi + 1;
    integer count = section_count(ch, mi);
    if (count <= 0) count = 0;

    // Collect this section's renderable entries, then the registered
    // ones. Notecard first, registered after, in registration order.
    list labels;
    list kinds;                 // "E" notecard entry, "R" registered
    list idx;                   // entry index, or REG index
    integer i = 0;
    while (i < count)
    {
        list e = entry(ch, first + i);
        string t = llList2String(e, 1);
        if (t == "P" || t == "S" || t == "T" || t == "B")
        {
            string lab = bare_name(llList2String(e, 0));
            if (t == "T") lab = lab + " >";
            labels += lab;
            kinds  += "E";
            idx    += (first + i);
        }
        ++i;
    }

    // Registered entries live in their own two submenus, exactly as v1
    // has them: [OPTIONS] for 90212 and [ADJUST] for 90213. Neither
    // exists as a notecard section, so both are synthesised here.
    string want = "";
    if (mi == SEC_OPTIONS) want = "O";
    if (mi == SEC_ADJUST)  want = "A";

    integer rn = llGetListLength(REG);
    integer nOpt = 0;
    integer nAdj = 0;
    i = 0;
    while (i < rn)
    {
        string dest = llList2String(REG, i + 1);
        integer flags = llList2Integer(REG, i + 4);
        integer show = TRUE;
        // flags bit 0 = owner-only.
        if (flags & 1)
        {
            if (av != llGetOwner()) show = FALSE;
        }
        if (show)
        {
            if (dest == "O") ++nOpt;
            else ++nAdj;
            if (dest == want)
            {
                labels += llList2String(REG, i);
                kinds  += "R";
                idx    += (i / REG_STRIDE);
            }
        }
        i += REG_STRIDE;
    }

    // The two doors, shown at the root only when something is behind
    // them. v1 self-shows [ADJUST] the same way (sitB.lsl:352).
    if (mi == -1)
    {
        if (nOpt) labels += "[OPTIONS]";
        if (nAdj) labels += "[ADJUST]";
    }

    integer total = llGetListLength(labels);
    integer pages = (total + PAGE - 1) / PAGE;
    if (pages < 1) pages = 1;
    if (page >= pages) page = 0;

    list btns;
    i = page * PAGE;
    integer stop = i + PAGE;
    if (stop > total) stop = total;
    while (i < stop)
    {
        btns += llList2String(labels, i);
        ++i;
    }
    if (mi != -1) btns += "[BACK]";
    if (pages > 1) btns += ["[<<]", "[>>]"];

    OPS = llListReplaceList(OPS, [page], row + 5, row + 5);
    OPS = llListReplaceList(OPS, [llGetUnixTime()], row + 7, row + 7);

    llDialog(av, "\n" + llGetObjectName(), btns, llList2Integer(OPS, row + 2));
}

// ------------------------------------------------------------- dispatch

click(integer op, string msg)
{
    integer row = op * OPS_STRIDE;
    key av       = (key)llList2String(OPS, row);
    integer ch   = llList2Integer(OPS, row + 1);
    integer mi   = llList2Integer(OPS, row + 4);
    integer page = llList2Integer(OPS, row + 5);
    string nav   = llList2String(OPS, row + 6);

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
        list st = llParseString2List(nav, [","], []);
        integer back = -1;
        integer len = llGetListLength(st);
        if (len > 0)
        {
            back = llList2Integer(st, len - 1);
            st = llDeleteSubList(st, len - 1, len - 1);
        }
        OPS = llListReplaceList(OPS, [back, 0, llDumpList2String(st, ",")],
            row + 4, row + 6);
        render(op);
        return;
    }

    if (msg == "[OPTIONS]" || msg == "[ADJUST]")
    {
        integer target = SEC_OPTIONS;
        if (msg == "[ADJUST]") target = SEC_ADJUST;
        string push = nav;
        if (push != "") push += ",";
        push += (string)mi;
        OPS = llListReplaceList(OPS, [target, 0, push], row + 4, row + 6);
        render(op);
        return;
    }

    // Re-derive the section rather than caching the page per operator.
    // A synthetic section has no notecard entries at all.
    integer first = mi + 1;
    integer count = section_count(ch, mi);
    if (mi < -1) count = 0;
    integer i = 0;
    while (i < count)
    {
        integer at = first + i;
        list e = entry(ch, at);
        string t = llList2String(e, 1);
        string lab = bare_name(llList2String(e, 0));
        if (t == "T") lab = lab + " >";

        if (lab == msg)
        {
            if (t == "T")
            {
                integer target = (integer)llLinksetDataRead(
                    "qs:nt:" + (string)ch + ":" + (string)at);
                string push = nav;
                if (push != "") push += ",";
                push += (string)mi;
                OPS = llListReplaceList(OPS, [target, 0, push], row + 4, row + 6);
                render(op);
                return;
            }
            if (t == "B")
            {
                // v1 payload: <channel>SEP<message>SEP<id>, where <C> is
                // the controller and <S> the seated avatar.
                list bd = llParseStringKeepNulls(llList2String(e, 2), [SEP], []);
                string bmsg = msg;
                if (llList2String(bd, 1) != "") bmsg = llList2String(bd, 1);
                key bid = av;
                if (llGetListLength(bd) > 2)
                {
                    string want = llList2String(bd, 2);
                    if (want != "<C>")
                    {
                        if (want != "<S>") bid = (key)want;
                    }
                }
                llMessageLinked(LINK_SET, llList2Integer(bd, 0), bmsg, bid);
                render(op);
                return;
            }
            // P or S. core gets the INDEX, because a label is not a
            // unique pose identity.
            llMessageLinked(LINK_SET, QSC_REQUEST,
                (string)ch + "|" + (string)at, av);
            render(op);
            return;
        }
        ++i;
    }

    // Registered entry?
    integer r = 0;
    integer rn = llGetListLength(REG);
    while (r < rn)
    {
        if (llList2String(REG, r) == msg)
        {
            llMessageLinked(LINK_SET, llList2Integer(REG, r + 2), msg, av);
            render(op);
            return;
        }
        r += REG_STRIDE;
    }

    // Unknown label: the page moved under the operator. Re-render.
    render(op);
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
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
        if (num == QSS_TOUCH || num == AV_MENUTOUSER)
        {
            // 90005 is the stock "send menu to user" number and is what
            // plugins and the HUD actually use, so it has to be accepted
            // here and not only the v2 one. Its id is either a plain
            // avatar key or a "<controller>|<sitter>" composite; the
            // controller is the one operating the menu.
            list who = llParseString2List((string)id, ["|"], []);
            key av = (key)llList2String(who, 0);
            if (av == "") return;

            // The toucher's own seat if they are sitting, otherwise the
            // seat whose prim they touched.
            integer ch = seat_of(av);
            if (ch < 0) ch = (integer)msg;
            if (ch < 0) ch = 0;
            render(op_open(av, ch));
            return;
        }

        if (num == QSPLUG_REGISTER || num == QSADJ_REGISTER)
        {
            // v1 payloads, unchanged so senders do not notice:
            //   90212  "<label>|<channel>|<scriptName>"
            //   90213  "<label>|<channel>|<scriptName>|<flags>"
            // Dedupe is by scriptName, so a re-announce after a reset
            // overwrites rather than appending a duplicate.
            list f = llParseString2List(msg, ["|"], []);
            string label = llList2String(f, 0);
            integer chan = llList2Integer(f, 1);
            string owner = llList2String(f, 2);
            if (label == "") return;
            if (chan == 0) return;
            if (owner == "") return;

            string dest = "O";
            integer flags = 0;
            if (num == QSADJ_REGISTER)
            {
                dest = "A";
                flags = llList2Integer(f, 3);
            }

            integer at = reg_find(owner);
            if (at >= 0)
                REG = llDeleteSubList(REG, at * REG_STRIDE,
                    at * REG_STRIDE + REG_STRIDE - 1);
            REG += [label, dest, chan, owner, flags];
            return;
        }

        if (num == AV_MENUCHOICE || num == AV_MENUNAV)
        {
            // The back route. "<slot>|<msg>|<controller>|<menuIndex>",
            // used by the HUD, the adjuster, [QS]faces and [QS]select to
            // inject a menu click as if the operator had pressed it.
            // Slot "X" is a wildcard for cross-slot routing.
            //
            // In v1 every sitB instance received this and had to filter
            // on its own channel, which is where the "clicking [ADJUST]
            // on slot 0 spawned a second dialog for slot 1" bug came
            // from. A singleton has no such ambiguity: the slot field
            // simply says which seat's menu to act on.
            list f = llParseStringKeepNulls(msg, ["|"], []);
            string sSlot = llList2String(f, 0);
            string what  = llList2String(f, 1);
            key who      = (key)llList2String(f, 2);
            if (what == "") return;
            if (who == "") return;

            integer ch = 0;
            if (sSlot != "X") ch = (integer)sSlot;

            // Reuse the operator's open dialog if there is one, so a
            // back-routed click lands in the menu they are looking at.
            integer op = op_of_avatar(who);
            if (op < 0) op = op_open(who, ch);
            click(op, what);
            return;
        }

        if (num == QSADJ_UNREGISTER)
        {
            // msg = scriptName, and since sitB 1.261 this drops EVERY
            // entry that script registered, not one. Needed because the
            // registry has no other removal path: a creator tool that
            // self-deletes on QS_FINALIZE must send this first, or its
            // button outlives it and dispatches to a dead channel.
            if (msg == "") return;
            reg_drop_owner(msg);
            return;
        }

        if (num == QSB_READY || num == QSB_RELOAD)
        {
            string v = llLinksetDataRead("qs:cfg:verbose");
            if (v != "") verbose = (integer)v;
            OPS = [];
            llSetTimerEvent(0.0);
            return;
        }
    }
}
