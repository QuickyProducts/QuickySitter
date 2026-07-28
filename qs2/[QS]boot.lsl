/*
 * [QS]boot - QuickySitter v2 notecard parser
 *
 * Reads the AVpos notecard in the v2 format and writes the LSD schema
 * every other v2 script reads. It is the only writer of the static keys.
 *
 * ONE DIALECT ONLY
 *
 * There is no v1 parser here and there will not be one. Legacy AVpos is
 * converted ahead of time by the web converter, which is where bytes are
 * free. What IS here is a ten-line dialect DETECTOR: a "SITTER" token
 * means somebody dropped v2 scripts into v1 furniture, and that has to
 * fail loudly with the converter's address rather than quietly building
 * an empty piece of furniture. See qs2/DESIGN.md §5.4.
 *
 * FORMAT (qs2/FORMAT.md)
 *
 *   ITEM <name>              optional; absent means one unnamed item
 *   SEAT <name>|<gender>|<rlv>
 *   PRIM <primName>          binds the most recent SEAT to a named prim
 *   MENU <path>[|hidden]     "/" nests; the parent button is automatic
 *   POSE <label> | <seat>=<anim> | …
 *   POS  <pose> | <seat> | <pos> | <rot>
 *
 * Indentation and blank lines carry no meaning. Order matters only for
 * display and for SEAT (fill order).
 *
 * WHY POSE LABELS ARE HELD IN RAM WHILE PARSING
 *
 * A POS line addresses its pose by label, so it needs a label→index
 * lookup. Doing that as an LSD scan costs O(poses) per POS line, and a
 * real notecard has hundreds of both. The transient list is dropped at
 * the end of each item.
 *
 * NOT BUILT YET, deliberately:
 *   - the [DUMP] path (server side moves first, DESIGN.md §5.4)
 *   - most carried-over tokens are parsed into qs:cfg:<item> but no v2
 *     script consumes them yet
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.01";

integer QSB_READY  = 90430;

string NOTECARD = "AVpos";
string CONVERTER = "https://quickyproducts.github.io/QuickySitter-docs/convert";

key    reader;
integer line_no;

string  cur_item;
integer item_idx;
integer item_first_seat;
integer item_seats;
integer seat_total;
integer pose_n;
integer menu_n;
string  cur_menu;
list    POSE_LABELS;      // transient, current item only
integer failed;

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

Fail(string s)
{
    failed = TRUE;
    llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

wipe()
{
    llLinksetDataDeleteFound("^qs:(i|s|p|o|m|pm|cfg|occ|cur|slot):", "");
}

// Close the item currently being parsed and write its index row.
close_item()
{
    if (cur_item == "") return;
    llLinksetDataWrite("qs:i:" + (string)item_idx,
        cur_item + "|" + (string)item_first_seat + "|" + (string)item_seats);
    llLinksetDataWrite("qs:p:" + cur_item + ":count", (string)pose_n);
    llLinksetDataWrite("qs:m:" + cur_item + ":count", (string)menu_n);
    POSE_LABELS = [];
    ++item_idx;
}

open_item(string name)
{
    close_item();
    cur_item = name;
    item_first_seat = seat_total;
    item_seats = 0;
    pose_n = 0;
    menu_n = 0;
    cur_menu = "";
}

// An absent ITEM means one unnamed item covering the whole linkset,
// which is exactly what every converted legacy notecard is.
ensure_item()
{
    if (cur_item == "") open_item(llGetObjectName());
}

parse(string raw)
{
    string s = llStringTrim(raw, STRING_TRIM);
    if (s == "") return;
    if (llGetSubString(s, 0, 0) == "#") return;

    integer sp = llSubStringIndex(s, " ");
    string tok;
    string rest = "";
    if (sp == -1) tok = s;
    else
    {
        tok = llGetSubString(s, 0, sp - 1);
        rest = llStringTrim(llGetSubString(s, sp + 1, -1), STRING_TRIM);
    }

    // The detector. Cheap, and it turns the worst support case into a
    // sentence the creator can act on.
    if (tok == "SITTER")
    {
        Fail("This notecard is in the old AVpos format. QuickySitter v2 reads"
           + " only the new format. Convert it here: " + CONVERTER);
        return;
    }

    if (tok == "ITEM")  { open_item(rest); return; }

    if (tok == "SEAT")
    {
        ensure_item();
        list f = llParseString2List(rest, ["|"], []);
        // name | gender | rlv | (prim filled in by a following PRIM line)
        llLinksetDataWrite("qs:s:" + (string)seat_total,
            llList2String(f, 0) + "||" + llList2String(f, 1) + "|" + llList2String(f, 2));
        ++seat_total;
        ++item_seats;
        return;
    }

    if (tok == "PRIM")
    {
        // Applies to the most recent SEAT. Kept as its own line rather
        // than a fourth positional field so no directive ever needs an
        // empty middle field, which is where KeepNulls parsing bites.
        if (seat_total == 0) return;
        integer at = seat_total - 1;
        list f = llParseStringKeepNulls(llLinksetDataRead("qs:s:" + (string)at), ["|"], []);
        llLinksetDataWrite("qs:s:" + (string)at,
            llList2String(f, 0) + "|" + rest + "|"
          + llList2String(f, 2) + "|" + llList2String(f, 3));
        return;
    }

    if (tok == "MENU")
    {
        ensure_item();
        list f = llParseString2List(rest, ["|"], []);
        string path = llList2String(f, 0);
        string flags = "";
        if (llList2String(f, 1) == "hidden") flags = "h";
        llLinksetDataWrite("qs:m:" + cur_item + ":" + (string)menu_n, path + "|" + flags);
        ++menu_n;
        cur_menu = path;
        return;
    }

    if (tok == "POSE")
    {
        ensure_item();
        list f = llParseString2List(rest, ["|"], []);
        integer i = 0;
        integer n = llGetListLength(f);
        string label = "";
        string row = "";
        while (i < n)
        {
            string part = llStringTrim(llList2String(f, i), STRING_TRIM);
            if (i == 0) label = part;
            else
            {
                if (llSubStringIndex(part, "=") == -1)
                {
                    // Single-seat shorthand: the animation with no seat
                    // name. Only legal when the item has exactly one seat
                    // (FORMAT.md §2), which is checked at the end.
                    if (item_seats == 1)
                    {
                        list s0 = llParseStringKeepNulls(
                            llLinksetDataRead("qs:s:" + (string)item_first_seat), ["|"], []);
                        part = llList2String(s0, 0) + "=" + part;
                    }
                    else
                    {
                        Fail("line " + (string)line_no + ": pose \"" + label
                           + "\" omits the seat name, but this item has "
                           + (string)item_seats + " seats.");
                        return;
                    }
                }
                row += "|" + part;
            }
            ++i;
        }
        llLinksetDataWrite("qs:p:" + cur_item + ":" + (string)pose_n, label + row);
        llLinksetDataWrite("qs:pm:" + cur_item + ":" + (string)pose_n, cur_menu);
        POSE_LABELS += label;
        ++pose_n;
        return;
    }

    if (tok == "POS")
    {
        // <pose> | <seat> | <pos> | <rot>
        list f = llParseString2List(rest, ["|"], []);
        string label = llStringTrim(llList2String(f, 0), STRING_TRIM);
        integer at = llListFindList(POSE_LABELS, [label]);
        if (at == -1)
        {
            // A typo here used to be a silent no-op that the creator only
            // met in-world as "the pose sits wrong". Now it is a line
            // number.
            Fail("line " + (string)line_no + ": POS names pose \"" + label
               + "\", which this item does not declare.");
            return;
        }
        llLinksetDataWrite("qs:o:" + cur_item + ":" + (string)at + ":"
            + llStringTrim(llList2String(f, 1), STRING_TRIM),
            llStringTrim(llList2String(f, 2), STRING_TRIM) + "|"
          + llStringTrim(llList2String(f, 3), STRING_TRIM));
        return;
    }

    if (tok == "VERBOSE")
    {
        verbose = (integer)rest;
        llLinksetDataWrite("qs:cfg:verbose", rest);
        return;
    }

    // Everything else is a carried-over token. Item-scope ones are stored
    // per item, the file-global ones under the empty item. Which is which
    // is FORMAT.md §4; no v2 script consumes them yet.
    if (llListFindList(["BRAND", "WARN", "KFM", "HELPER"], [tok]) != -1)
    {
        llLinksetDataWrite("qs:cfg::" + tok, rest);
        return;
    }
    ensure_item();
    llLinksetDataWrite("qs:cfg:" + cur_item + ":" + tok, rest);
}

default
{
    state_entry()
    {
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;

        if (llGetInventoryType(NOTECARD) != INVENTORY_NOTECARD)
        {
            Fail("No \"" + NOTECARD + "\" notecard in this prim.");
            return;
        }
        wipe();
        cur_item = "";
        item_idx = 0;
        seat_total = 0;
        line_no = 0;
        failed = FALSE;
        POSE_LABELS = [];
        reader = llGetNotecardLine(NOTECARD, 0);
    }

    dataserver(key q, string data)
    {
        if (q != reader) return;
        if (data == EOF)
        {
            close_item();
            llLinksetDataWrite("qs:i:count", (string)item_idx);
            llLinksetDataWrite("qs:s:count", (string)seat_total);
            if (failed) return;
            Out(0, "ready: " + (string)item_idx + " item(s), "
                + (string)seat_total + " seat(s), mem=" + (string)llGetFreeMemory());
            llMessageLinked(LINK_SET, QSB_READY, "", "");
            return;
        }
        ++line_no;
        parse(data);
        if (failed) return;
        reader = llGetNotecardLine(NOTECARD, line_no);
    }

    changed(integer change)
    {
        if (change & CHANGED_INVENTORY) llResetScript();
    }
}
