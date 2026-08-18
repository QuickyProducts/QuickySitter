/*
 * [QS]AVpos-shifter - QuickySitter fork of the AVsitter AVpos-shifter
 *
 * Creator tool. Shifts every pose and prop position/rotation in an AVpos
 * notecard by an offset, or rebases the whole notecard onto a different
 * prim. Reads the notecard, prints the converted text between two cut
 * markers, and uploads the same text so it can be copied from a browser
 * instead of out of chat history.
 *
 * Usage (owner only):
 *   /5 <0,0,1.5>            shift all positions
 *   /6 <0,0,180>            rotate all positions about the prim center
 *   /5 <0,0,1.5>,<0,0,180>  both at once
 *   touch a child prim      rebase the notecard onto that prim
 *
 * Differences from the stock AVsitter utility:
 *
 *   1. Uploads to the QuickySitter receiver (qs/php/settings.php on
 *      slquicky.com) instead of avsitter.com, which no longer accepts
 *      QuickySitter output (issue #66). Identical w/c/t POST plus ?q GET
 *      wire protocol and the same "\n\nend" final-chunk sentinel, so this
 *      is a URL swap and not a rewrite.
 *
 *   2. Warns before every conversion when it finds fork storage in the
 *      linkset. On QuickySitter the AVpos notecard is a seed, not the
 *      live store: [SAVE] writes pose defaults to LSD qs:p:<ch>:<i> and
 *      never rewrites the notecard. Shifting a notecard that is behind
 *      the live data converts stale numbers, and saving the result mints
 *      a new asset key, which trips boot's CHANGED_INVENTORY wipe and
 *      drops every saved position. [ADJUST] > [HELPER] > [DUMP] into the
 *      notecard first. The warning is unconditional because nothing
 *      distinguishes "seeded and never touched" from "adjusted since",
 *      and a warning that is sometimes redundant beats a guess that is
 *      sometimes silently wrong.
 *
 *   3. Does not delete itself after a conversion. Stock removed itself on
 *      every run, so two shifts cost two copies of the script and a run
 *      that failed cost one for nothing. Teardown follows the fork's
 *      finalization contract instead: QS_FINALIZE (90215), broadcast by
 *      [QS]adjuster on '/5 cleanup'. See qs/PROTOCOL.md.
 *
 *   4. Does not require the root prim and never deletes itself over
 *      placement. QuickySitter furniture legitimately keeps its scripts
 *      and the AVpos notecard in a child prim, and losing the only copy
 *      of a creator tool is a bad trade for a check a chat line makes
 *      just as well. All this script needs is the notecard beside it.
 *
 *   5. Stays quiet on channel-5 traffic that is not ours. Channel 5 is
 *      shared with [QS]adjuster ('/5 cleanup', '/5 helper', '/5 targets',
 *      '/5 adjust owner|group|all') and with the rezzed [AV]helper stick
 *      ('/5 <uuid>'). Stock answered all of it with "You didn't enter a
 *      vector!".
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "1.28";
string notecard_name = "AVpos";

// Self-hosted dump receiver, same endpoint [QS]boot posts its [DUMP] to.
// Changing the deploy location means bumping this string; there is
// deliberately no notecard override, it is a fork-level decision.
string url = "https://slquicky.com/quicky-sitter/dump/settings.php";

// QS_FINALIZE - '/5 cleanup' broadcast from [QS]adjuster. Creator-only
// tools tear THEMSELVES down on it; the owner typing the command is the
// confirmation. We publish no qs:alive flag, so unlike the self-removing
// scripts in PROTOCOL.md there is no presence flag to delete first.
integer QS_FINALIZE = 90215;

key notecard_query;
integer notecard_line;
vector target_prim_pos;
rotation target_prim_rot;
// Frame the numbers in the notecard are ALREADY expressed in, as a
// root-local transform. AVpos positions are local to the prim that holds
// [QS]sitA — sitA seats avatars with prim params of its own prim, they are
// not root-local — and by project layout that is this prim, since we read
// the AVpos out of our own inventory.
//
// Zero for the /5 and /6 offset paths: those shift the numbers inside their
// own frame and must not be reframed. Set only for the touch rebase, which
// genuinely changes frames. ZERO_ROTATION is the identity quaternion and
// ZERO_VECTOR adds nothing, so the offset paths compute exactly what they
// computed before this existed.
vector source_prim_pos;
rotation source_prim_rot;
string cache;
string webkey;
integer webcount;

// Set while a conversion is walking the notecard. Stock had no such flag
// because it removed itself after the single run it ever did.
integer converting;

web(string say, integer force)
{
    cache += say;
    if (llStringLength(llEscapeURL(cache)) > 1024 || force)
    {
        ++webcount;
        llHTTPRequest(url, [HTTP_METHOD, "POST", HTTP_MIMETYPE, "application/x-www-form-urlencoded", HTTP_VERIFY_CERT, FALSE], "w=" + webkey + "&c=" + (string)webcount + "&t=" + llEscapeURL(cache));
        cache = "";
    }
}

integer IsVector(string s)
{
    list split = llParseString2List(s, [" "], ["<", ">", ","]);
    if (llGetListLength(split) != 7)
        return FALSE;
    return !((string)((vector)s) == (string)((vector)((string)llListInsertList(split, ["-"], 5))));
}

string FormatFloat(float f, integer num_decimals)
{
    float rounding = (float)(".5e-" + (string)num_decimals) - .5e-6;
    if (f < 0.)
        f -= rounding;
    else
        f += rounding;
    string ret = llGetSubString((string)f, 0, num_decimals - (!num_decimals) - 7);
    if (llSubStringIndex(ret, ".") != -1)
    {
        while (llGetSubString(ret, -1, -1) == "0")
        {
            ret = llGetSubString(ret, 0, -2);
        }
    }
    if (llGetSubString(ret, -1, -1) == ".")
    {
        ret = llGetSubString(ret, 0, -2);
    }
    return ret;
}

instructions()
{
    llOwnerSay("\n\n" + llGetScriptName() + " " + version + "\n\n"
        + "MOVE ALL POSE & PROP POSITIONS BY AN OFFSET:\n"
        + "  /5 <0,0,1.5>             position offset\n"
        + "  /6 <0,0,180>             rotation offset in degrees, about the prim center\n"
        + "  /5 <0,0,1.5>,<0,0,180>   both at once (comma between the two vectors)\n\n"
        + "RELOCATE A SETUP TO ANOTHER PRIM:\n"
        + "  Touch the prim you want the poses moved to. That prim should be\n"
        + "  empty or hold a script with llPassTouches(TRUE).\n\n"
        + "The converted notecard is printed in chat between the two cut markers\n"
        + "and uploaded to a web page whose link comes at the end. Paste the\n"
        + "result back into \"" + notecard_name + "\" and save it.\n\n"
        + "ON QUICKYSITTER, DUMP FIRST: positions saved with [SAVE] live in the\n"
        + "furniture, not in the notecard. Run [ADJUST] > [HELPER] > [DUMP] and\n"
        + "paste that into \"" + notecard_name + "\" before you shift, otherwise\n"
        + "this converts stale numbers and saving the result throws your saved\n"
        + "positions away.\n\n"
        + "This tool stays in the prim until you finalize the build with\n"
        + "'/5 cleanup' (or delete it by hand).\n");
}

cut_above_text()
{
    webkey = (string)llGenerateKey();
    webcount = 0;
    Readout_Say("");
    Readout_Say("--✄--COPY BELOW INTO \"" + notecard_name + "\" NOTECARD--✄--");
    Readout_Say("");
}

cut_below_text()
{
    Readout_Say("");
    Readout_Say("--✄--COPY ABOVE INTO \"" + notecard_name + "\" NOTECARD--✄--");
    Readout_Say("");
}

Readout_Say(string say)
{
    llSleep(0.1);
    string objectname = llGetObjectName();
    llSetObjectName("");
    llRegionSayTo(llGetOwner(), 0, "◆" + say);
    llSetObjectName(objectname);
    web(say + "\n", FALSE);
}

// Stock tested for link 1 AND the notecard, then removed itself when
// either was missing. Only the notecard half is a real requirement.
integer check_notecard()
{
    if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
    {
        return TRUE;
    }
    llOwnerSay("No \"" + notecard_name + "\" notecard in this prim. Move me into the prim that holds it.");
    return FALSE;
}

// See header note 2. Emitted per conversion, not per script reset, so it
// lands at the moment it can still change what the creator does next.
qs_stale_notecard_warning()
{
    if (llLinksetDataRead("qs:boot:asset") == "") return;
    llOwnerSay("\nQuickySitter storage found in this linkset.\n"
        + "Pose positions saved with [SAVE] live in the furniture, NOT in the \""
        + notecard_name + "\" notecard. If anything has been adjusted since \""
        + notecard_name + "\" was last written, run [ADJUST] > [HELPER] > [DUMP]\n"
        + "and paste that into \"" + notecard_name + "\" BEFORE shifting. Otherwise\n"
        + "this converts stale numbers, and saving the shifted notecard re-seeds\n"
        + "the furniture from them and discards what you had saved.\n");
}

// Single entry point for all three triggers. Stock inlined this three
// times and reset notecard_line in only one of them, which was harmless
// while the script deleted itself after one run and is not harmless now:
// a second conversion would resume past EOF and print an empty result.
// The offsets are reset by the callers for the same reason, so a /6 after
// a /5 does not inherit the earlier position shift.
// A run in progress owns the conversion transform: the dataserver loop reads
// target_prim_pos/rot per line, so a second command that writes them mid-run
// converts the REST of the notecard with the new values and prints a
// silently mixed-frame result. Both trigger paths therefore ask this BEFORE
// touching anything, not after — start_conversion's own check came too late,
// the globals were already overwritten by then.
integer busy()
{
    if (!converting) return FALSE;
    llOwnerSay("Still converting. Wait for the closing cut marker before starting another run. If the notecard was removed mid-run, reset this script.");
    return TRUE;
}

start_conversion()
{
    if (busy()) return;
    if (!check_notecard()) return;
    qs_stale_notecard_warning();
    converting = TRUE;
    notecard_line = 0;
    cache = "";
    cut_above_text();
    notecard_query = llGetNotecardLine(notecard_name, notecard_line);
}

default
{
    state_entry()
    {
        check_notecard();
        instructions();
        llListen(5, "", llGetOwner(), "");
        llListen(6, "", llGetOwner(), "");
    }

    touch_start(integer touched)
    {
        // Owner-only, unlike stock. A conversion spams the owner's chat
        // and posts an upload; a visitor's touch should not start one.
        if (llDetectedKey(0) != llGetOwner()) return;
        if (llDetectedLinkNumber(0) <= 1) return;
        if (busy()) return;
        target_prim_pos = llList2Vector(llGetLinkPrimitiveParams(llDetectedLinkNumber(0), [PRIM_POS_LOCAL]), 0);
        target_prim_rot = llList2Rot(llGetLinkPrimitiveParams(llDetectedLinkNumber(0), [PRIM_ROT_LOCAL]), 0);
        // The rebase converts BETWEEN two prim frames, so it needs both ends.
        // Stock only ever had one because it refused to run outside the root
        // (it deleted itself there), where the source frame is the identity.
        // This fork allows the child-prim layout QuickySitter actually uses,
        // and without our own transform every rebased number came out wrong
        // by exactly this prim's offset from the root.
        source_prim_pos = llList2Vector(llGetLinkPrimitiveParams(LINK_THIS, [PRIM_POS_LOCAL]), 0);
        source_prim_rot = llList2Rot(llGetLinkPrimitiveParams(LINK_THIS, [PRIM_ROT_LOCAL]), 0);
        llOwnerSay("Converting " + notecard_name + " for use in prim #" + (string)llDetectedLinkNumber(0));
        start_conversion();
    }

    listen(integer chan, string name, key id, string msg)
    {
        // See header note 5. A '<' is the entry ticket: no [QS]adjuster
        // command and no avatar UUID contains one, and LSL's vector cast
        // needs the angle brackets anyway.
        if (llSubStringIndex(msg, "<") == -1) return;

        vector v = (vector)msg;
        if (v == ZERO_VECTOR)
        {
            llOwnerSay("That is not a vector. Use /5 <0,0,1.5> or /6 <0,0,180>.");
            return;
        }

        if (busy()) return;
        // Offsets move the numbers inside their own frame; no reframing.
        source_prim_pos = ZERO_VECTOR;
        source_prim_rot = ZERO_ROTATION;

        if (chan == 5)
        {
            llOwnerSay("Converting positions in " + notecard_name + " by offset: " + (string)v);
            target_prim_pos = -v;
            target_prim_rot = ZERO_ROTATION;
            // llCSV2List keeps a <...> group together, so element 1 is the
            // optional second vector of '/5 <pos>,<rot>'.
            v = (vector)llList2String(llCSV2List(msg), 1);
            if (v != ZERO_VECTOR)
            {
                llOwnerSay("Converting rotations in " + notecard_name + " by offset: " + (string)v);
                target_prim_rot = llEuler2Rot(v * DEG_TO_RAD);
            }
        }
        else
        {
            llOwnerSay("Converting rotations in " + notecard_name + " by offset: " + (string)v);
            target_prim_pos = ZERO_VECTOR;
            target_prim_rot = llEuler2Rot(v * DEG_TO_RAD);
        }
        start_conversion();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num != QS_FINALIZE) return;
        llRegionSayTo(llGetOwner(), 0, llGetScriptName() + ": removed by /5 cleanup.");
        llRemoveInventory(llGetScriptName());
    }

    dataserver(key query_id, string data)
    {
        if (query_id != notecard_query) return;

        if (data == EOF)
        {
            cut_below_text();
            web("\n\nend", TRUE);
            converting = FALSE;
            llOwnerSay("Conversion complete. Paste the result into \"" + notecard_name + "\" and save it.");
            llRegionSayTo(llGetOwner(), 0, "Settings copy: " + url + "?q=" + webkey);
            llRegionSayTo(llGetOwner(), 0, "(Append &raw=1 to that link for the byte-exact stream instead of the grouped layout.)");
            llOwnerSay("This tool is still in the prim. Finalize with '/5 cleanup' before handing the build out.");
            return;
        }

        data = llStringTrim(llGetSubString(data, llSubStringIndex(data, "◆") + 1, 99999), STRING_TRIM);
        if (llGetSubString(data, 0, 0) == "{")
        {
            string command = llStringTrim(llGetSubString(data, 1, llSubStringIndex(data, "}") - 1), STRING_TRIM);
            data = llDumpList2String(llParseString2List(data, [" "], [""]), "");
            data = llGetSubString(data, llSubStringIndex(data, "}") + 1, 99999);
            list parts = llParseStringKeepNulls(data, ["<"], []);
            vector pos = (vector)("<" + llList2String(parts, 1));
            pos = ((pos * source_prim_rot + source_prim_pos) - target_prim_pos) / target_prim_rot;
            rotation rot = llEuler2Rot((vector)("<" + llList2String(parts, 2)) * DEG_TO_RAD);
            vector vec_rot = llRot2Euler((rot * source_prim_rot) / target_prim_rot) * RAD_TO_DEG;
            string result = "<" + FormatFloat(pos.x, 3) + "," + FormatFloat(pos.y, 3) + "," + FormatFloat(pos.z, 3) + ">";
            result += "<" + FormatFloat(vec_rot.x, 1) + "," + FormatFloat(vec_rot.y, 1) + "," + FormatFloat(vec_rot.z, 1) + ">";
            Readout_Say("{" + command + "}" + result);
        }
        // Stock quirk, preserved on purpose: llSubStringIndex of a one-char
        // string in "PROP" is always -1, so this branch takes EVERY line
        // that is not a {} position line. That is why it works. PROP lines
        // get their two vectors converted, everything else is rebuilt from
        // its own '|' parts unchanged, and a blank line stays blank. Do not
        // "fix" the test into a real PROP match without also routing the
        // pass-through lines somewhere, or the notecard loses them.
        else if (llSubStringIndex(llGetSubString(data, 0, 0), "PROP"))
        {
            integer index;
            vector pos;
            rotation rot;
            list parts = llParseStringKeepNulls(data, ["|"], [""]);
            if (IsVector(llList2String(parts, 2)) && IsVector(llList2String(parts, 3)))
            {
                index = 2;
            }
            else if (IsVector(llList2String(parts, 3)) && IsVector(llList2String(parts, 4)))
            {
                index = 3;
            }
            if (index)
            {
                pos = (vector)llList2String(parts, index);
                rot = llEuler2Rot((vector)llList2String(parts, index + 1) * DEG_TO_RAD);
                pos = ((pos * source_prim_rot + source_prim_pos) - target_prim_pos) / target_prim_rot;
                vector vec_rot = llRot2Euler((rot * source_prim_rot) / target_prim_rot) * RAD_TO_DEG;
                string pos_string = "<" + FormatFloat(pos.x, 3) + "," + FormatFloat(pos.y, 3) + "," + FormatFloat(pos.z, 3) + ">";
                string rot_string = "<" + FormatFloat(vec_rot.x, 1) + "," + FormatFloat(vec_rot.y, 1) + "," + FormatFloat(vec_rot.z, 1) + ">";
                parts = llListReplaceList(parts, [pos_string, rot_string], index, index + 1);
            }
            Readout_Say(llDumpList2String(parts, "|"));
        }
        else if (data != "")
        {
            Readout_Say(data);
        }
        notecard_query = llGetNotecardLine(notecard_name, ++notecard_line);
    }
}
