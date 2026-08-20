string version = "0.9";
/*
 * [QS]propRezzer - one-shot prop unpacking for script migration
 *
 * Drop-in authoring helper (adjuster pattern: presence = tool, remove
 * after use). On an owner chat command it rezzes every OBJECT in this
 * prim's inventory once, dormant, on a grid above the furniture, so a
 * creator can open each rezzed copy, swap the prop-side scripts
 * ([AV]object + [QS]objectadjust -> [QS]object), take it back and
 * replace the inventory original. Built for the PROP2 migration where
 * a 60-prop build would otherwise mean 60 rounds of copy-out and
 * hand-rez; see plugins/prop2/README.md.
 *
 * Commands (public chat channel 5, owner only):
 *   /5 rezall        rez the grid, 1 m spacing, plus a chat manifest
 *   /5 rezall 2      same with 2 m spacing
 *   /5 proplist      manifest only, nothing rezzed
 *
 * Why the rezzed copies are DORMANT: they go out with start parameter
 * 0. Both stock [AV]object and [QS]object gate their active state on a
 * non-zero rez parameter, so the copies open no listen, join no
 * channel, never attach and never time out - inert objects that only
 * want to be edited. Attach props therefore need no special handling:
 * without a handshake there is no ATTACHTO, they lie in the grid like
 * everything else.
 *
 * That dormancy is also why there is NO cleanup command: a dormant
 * prop hears nothing, and any non-zero parameter would put stock
 * [AV]object into its half-awake corpse state instead. The creator
 * opens every object anyway; taking or deleting the copy afterwards
 * is part of the same hand motion.
 *
 * No-copy objects are SKIPPED with a warning: rezzing a no-copy
 * inventory object would move it out of the furniture.
 *
 * The manifest annotates each object from the qs:prop:* LSD store
 * (readable linkset-wide, no prop2 round trip): prop type, attach
 * point, or "dynamic attach" for QSDYN-only rows, so invisible props
 * (the alpha-0 HUD) are identifiable by their grid slot. Viewer tip
 * printed with every run: Ctrl+Alt+T highlights transparent objects.
 */

integer LISTEN_CHANNEL = 5;

Out(string out)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
}

integer prop_db_count()
{
    list mp = llParseStringKeepNulls(
        llLinksetDataRead("qs:prop:meta"), ["\t"], []);
    return (integer)llList2String(mp, 1);
}

// One line of prop-DB context for an inventory object name. O(count)
// LSD reads per object; a one-shot authoring tool can afford it.
string annotate(string obj)
{
    integer count = prop_db_count();
    integer uses;
    string note = "";
    integer i;
    for (i = 0; i < count; i++)
    {
        list entry = llParseStringKeepNulls(
            llLinksetDataRead("qs:prop:" + (string)i), ["\t"], []);
        if (llList2String(entry, 2) == obj)
        {
            uses++;
            if (note == "")
            {
                list grp = llParseStringKeepNulls(
                    llList2String(entry, 3), ["|"], []);
                integer ptype = (integer)llList2String(entry, 1);
                if (llList2String(grp, 1) == "QSDYN")
                {
                    note = "dynamic attach";
                }
                else if (ptype == 0)
                {
                    note = "world";
                }
                else if (ptype == 3)
                {
                    note = "world (stay)";
                }
                else
                {
                    note = "PROP" + (string)ptype;
                    string pt = llList2String(entry, 6);
                    if (pt != "")
                    {
                        note += ", " + pt;
                    }
                }
            }
        }
    }
    if (note == "")
    {
        return "not in prop DB";
    }
    return note + ", " + (string)uses + " line(s)";
}

// Rez (spacing > 0) or just list (spacing == 0) every inventory
// object. Grid: furniture-local XY plane, centered on the root, 1.5 m
// above it, aligned to the furniture rotation.
run(float spacing)
{
    integer n = llGetInventoryNumber(INVENTORY_OBJECT);
    if (n == 0)
    {
        Out("No objects in this prim's inventory.");
        return;
    }
    integer cols = (integer)llCeil(llSqrt((float)n));
    integer rows_total = (n + cols - 1) / cols;
    vector root_pos = llGetRootPosition();
    rotation root_rot = llGetRootRotation();
    integer rezzed;
    integer i;
    for (i = 0; i < n; i++)
    {
        string obj = llGetInventoryName(INVENTORY_OBJECT, i);
        if (spacing > 0.0
            && !(llGetInventoryPermMask(obj, MASK_OWNER) & PERM_COPY))
        {
            Out("SKIPPED (no-copy, rezzing would remove it from the"
                + " furniture): '" + obj + "'");
        }
        else
        {
            string place = "";
            if (spacing > 0.0)
            {
                integer col = rezzed % cols;
                integer row = rezzed / cols;
                vector offset;
                offset.x = ((float)col - (float)(cols - 1) * 0.5) * spacing;
                offset.y = ((float)row - (float)(rows_total - 1) * 0.5) * spacing;
                offset.z = 1.5;
                llRezAtRoot(obj, root_pos + offset * root_rot,
                    ZERO_VECTOR, root_rot, 0);
                rezzed++;
                place = " - row " + (string)(row + 1)
                    + ", slot " + (string)(col + 1);
                llSleep(0.15);
            }
            Out("[" + (string)(i + 1) + "/" + (string)n + "] '" + obj
                + "' - " + annotate(obj) + place);
        }
    }
    if (spacing > 0.0)
    {
        Out((string)rezzed + " dormant copies rezzed (start param 0)."
            + " Edit, then take or delete them BY HAND - dormant props"
            + " hear no cleanup command.");
        Out("Viewer tip: Ctrl+Alt+T highlights transparent objects"
            + " (finds alpha-0 props like the HUD).");
    }
}

default
{
    state_entry()
    {
        llListen(LISTEN_CHANNEL, "", llGetOwner(), "");
        Out("ready - /" + (string)LISTEN_CHANNEL
            + " rezall [spacing] | /" + (string)LISTEN_CHANNEL
            + " proplist. Remove this script after the migration.");
    }

    on_rez(integer start)
    {
        llResetScript();
    }

    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            llResetScript();
        }
    }

    listen(integer channel, string name, key id, string message)
    {
        list words = llParseString2List(message, [" "], []);
        string cmd = llToLower(llList2String(words, 0));
        if (cmd == "rezall")
        {
            float spacing = (float)llList2String(words, 1);
            if (spacing <= 0.0)
            {
                spacing = 1.0;
            }
            run(spacing);
        }
        else if (cmd == "proplist")
        {
            run(0.0);
        }
    }
}
