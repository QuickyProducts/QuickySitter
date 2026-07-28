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
 *   OFFSETS <seat>           opens an offset block for one seat
 *   {label}<pos><rot>        offset line, v1-shaped, no separators
 *
 * Indentation and blank lines carry no meaning. Order matters only for
 * display, for SEAT (fill order), and for offset lines (they belong to
 * the OFFSETS block above them).
 *
 * WHY POSE LABELS ARE HELD IN RAM WHILE PARSING
 *
 * An offset line addresses its pose by label, so it needs a label→index
 * lookup, and an LSD scan would cost O(poses) per line with hundreds of
 * both. Two parallel lists, not one, because a label is not unique: the
 * seat has to be matched too. Dropped at the end of each item.
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
// Transient, current item only. Two parallel lists rather than one:
// a label is NOT unique (the "Lalou" notecard has a slot-local POSE
// named "Sit" for each sitter), so an offset line has to be matched on
// label AND seat or it lands on the wrong pose.
list    POSE_LABELS;
list    POSE_SEATS;       // comma-joined seat names per pose
string  cur_off_seat;     // set by the most recent OFFSETS line
integer failed;

integer find_pose(string label, string seatName)
{
    integer i = 0;
    integer n = llGetListLength(POSE_LABELS);
    while (i < n)
    {
        if (llList2String(POSE_LABELS, i) == label)
        {
            if (seatName == "") return i;
            if (llListFindList(llParseString2List(
                    llList2String(POSE_SEATS, i), [","], []), [seatName]) != -1)
                return i;
        }
        ++i;
    }
    return -1;
}

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
    POSE_SEATS = [];
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
    cur_off_seat = "";
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

    // Offset line, kept in v1's shape on purpose: "{label}<pos><rot>",
    // no separators, because the braces and angle brackets already
    // delimit. The seat comes from the OFFSETS line above rather than
    // from the line itself, which is what makes this byte-identical to
    // v1 instead of ~37% longer. See FORMAT.md §2.
    if (llGetSubString(s, 0, 0) == "{")
    {
        integer close = llSubStringIndex(s, "}");
        if (close < 2) return;
        string label = llGetSubString(s, 1, close - 1);
        string v = llGetSubString(s, close + 1, -1);
        integer split = llSubStringIndex(v, "><");
        if (split == -1) return;
        integer at = find_pose(label, cur_off_seat);
        if (at == -1)
        {
            // v1 swallowed this silently, and the creator met it in-world
            // as "the pose sits wrong". Now it is a line number.
            Fail("line " + (string)line_no + ": offset names pose \"" + label
               + "\" for seat \"" + cur_off_seat + "\", which is not declared.");
            return;
        }
        llLinksetDataWrite("qs:o:" + cur_item + ":" + (string)at + ":" + cur_off_seat,
            llGetSubString(v, 0, split) + "|" + llGetSubString(v, split + 1, -1));
        return;
    }

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
        string seats = "";
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
                if (seats != "") seats += ",";
                seats += llGetSubString(part, 0, llSubStringIndex(part, "=") - 1);
            }
            ++i;
        }
        llLinksetDataWrite("qs:p:" + cur_item + ":" + (string)pose_n, label + row);
        llLinksetDataWrite("qs:pm:" + cur_item + ":" + (string)pose_n, cur_menu);
        POSE_LABELS += label;
        POSE_SEATS += seats;
        ++pose_n;
        return;
    }

    if (tok == "OFFSETS")
    {
        // Opens a block of offset lines for one seat. The seat is named
        // once here instead of once per line, which is the whole reason
        // this section costs the same as v1 rather than a third more.
        cur_off_seat = rest;
        return;
    }

    if (tok == "VERBOSE")
    {
        verbose = (integer)rest;
        llLinksetDataWrite("qs:cfg:verbose", rest);
        return;
    }

    // Repeatable content tokens. These occur many times per item, so they
    // are stored indexed. Collapsing them into one key each, as an earlier
    // draft of this parser did, silently loses every line but the last.
    // Stored but NOT consumed by any v2 script yet — see qs2/STATUS.md.
    // PROP without a digit is used alongside PROP1/2/3 in real notecards
    // ("Lalou" uses both), so it has to be listed or those lines vanish.
    if (llListFindList(["BUTTON", "SEQUENCE", "PROP", "PROP1", "PROP2", "PROP3"], [tok]) != -1)
    {
        ensure_item();
        string ck = "qs:x:" + cur_item + ":" + tok + ":count";
        integer at = (integer)llLinksetDataRead(ck);
        llLinksetDataWrite("qs:x:" + cur_item + ":" + tok + ":" + (string)at,
            cur_menu + "|" + rest);
        llLinksetDataWrite(ck, (string)(at + 1));
        return;
    }

    // Single-valued carried-over tokens. File-global ones go under the
    // empty item, item-scope ones under their item (FORMAT.md §4). Parsed
    // and stored, consumed by nothing yet.
    if (llListFindList(["BRAND", "WARN", "KFM", "HELPER"], [tok]) != -1)
    {
        llLinksetDataWrite("qs:cfg::" + tok, rest);
        return;
    }
    // Anything left that is not a plain uppercase token is decoration, not
    // a directive. Real notecards carry separator lines like "--------",
    // and storing those as configuration keys is how LSD fills up with
    // rubbish.
    integer c = 0;
    integer L = llStringLength(tok);
    while (c < L)
    {
        string ch = llGetSubString(tok, c, c);
        if (llSubStringIndex("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_", ch) == -1) return;
        ++c;
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
