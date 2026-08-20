string version = "0.9";
/*
 * [QS]object - prop-side script for the PROP2 pair
 *
 * Merges stock [AV]object 2.020 and [QS]objectadjust 1.28 into ONE
 * script. Ships in the prop's ROOT prim as the only prop script,
 * replacing the stock pair. Pairs with [QS]prop2 on the furniture side;
 * also runs under [QS]prop / stock [AV]prop on wire v1 (negative
 * start_param), where it behaves like the old pair did.
 *
 * MUST be compiled in-world under the QuickyProducts experience: the
 * no-dialog temp-attach relies on llRequestExperiencePermissions. On
 * land without the experience it degrades to the stock fallback dialog
 * (llRequestPermissions after denial), exactly like [AV]object does.
 *
 * New over the merged pair:
 *   - Wire v2 decode. The sign of the start parameter picks the
 *     decoder: positive = bit-packed v2 (see [QS]prop2 header),
 *     <= -10000000 = stock decimal digit-slicing.
 *   - Rezzer scoping: comm-channel commands are honoured only when the
 *     speaker's root prim is the object that rezzed us. Two furnitures
 *     colliding on one random channel can no longer derez each other's
 *     props or steal SAVE replies. Works on wire v1 too, so a single
 *     swapped prop is protected even among stock siblings.
 *   - One decoder, one listen, one timer. The 2-second click-action
 *     deferral [QS]objectadjust needed to avoid racing [AV]object's
 *     state_entry is gone - the click action is decided once, here.
 *   - llSetMemoryLimit cuts the per-prop parcel script memory from
 *     2 x 64 KB (stock pair, no limit set) to one small allocation.
 *
 * Wire (all region-says on comm_channel, unchanged from the pair):
 *   REZ/ATTACHED/DETACHED/DEREZ|<id>   prop -> furniture handshake
 *   ATTACHTO|<av>|<key>                furniture -> prop: attach to av
 *   REM_ALL / REM_INDEX|i… / REM_WORLD|i… / REM_WORN|<av>
 *   PROPSEARCH                          -> SAVEPROP|<id> (world only)
 *                                       -> QSSAVESCALE|<id>|<factor>
 *                                       -> QSSAVEWORN|<id>|<pos>|<rot>
 *                                          (only while attached)
 *   QSSCALE|<id>|<factor>              furniture -> prop: apply factor
 *   QSWORN|<id>|<pos>|<rot>            furniture -> prop: cache worn fit
 *
 * Original [AV]object license preserved - fork inherits MPL 2.0:
 *
 * [AV]object - Used in props for attaching, derezzing, etc.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

integer comm_channel;
integer local_attach_channel = -2907539;
integer listen_handle;
integer prop_type;
integer prop_id;
integer prop_point;
integer experience_denied_reason;
key originalowner;
key parentkey;
integer watchdog;       // orphan check armed (stock timer condition)

// [QS]objectadjust merge: scale + worn fit + owner size menu
vector  base_scale;     // root scale at rez = inventory scale (factor 1)
integer worn_set;       // TRUE once QSWORN delivered a persisted fit
vector  worn_pos;       // local pos vs attach point
rotation worn_rot;      // local rot vs attach point
integer dlg_channel;
integer dlg_handle;
integer dlg_deadline;   // llGetUnixTime cutoff for the menu listen

unsit_all()
{
    integer i = llGetNumberOfPrims();
    while (llGetAgentSize(llGetLinkKey(i)) != ZERO_VECTOR)
    {
        llUnSit(llGetLinkKey(i));
        i--;
    }
}

// Rezzer scoping: TRUE when the speaking prim belongs to the object
// that rezzed us. parentkey is the rezzer's root key (OBJECT_REZZER_KEY
// of self, captured at state_entry like stock already did - stock just
// never checked it in listen). A speaker from another linkset, or an
// avatar, resolves to a different root and is ignored.
integer from_parent(key id)
{
    return llList2Key(llGetObjectDetails(id, [OBJECT_ROOT]), 0) == parentkey;
}

float current_factor()
{
    // LSL forbids member access on a call result (llGetScale().x) -
    // store the vector first.
    vector cur = llGetScale();
    return cur.x / base_scale.x;
}

// Scale the whole linkset by rel (relative to CURRENT size), clamped to
// what llScaleByFactor allows. `who` gets a chat note on hard failure
// (NULL_KEY = silent, used for the rez-time QSSCALE apply).
scale_rel(float rel, key who)
{
    // stay slightly within the reported limits - exact values fail on
    // float precision (llScaleByFactor wiki caveat)
    float lo = llGetMinScaleFactor() * 1.001;
    float hi = llGetMaxScaleFactor() * 0.999;
    if (rel < lo) rel = lo;
    if (rel > hi) rel = hi;
    if (rel > 0.9999 && rel < 1.0001) return;
    if (!llScaleByFactor(rel))
    {
        if (who)
        {
            llRegionSayTo(who, 0, llGetObjectName()
                + ": cannot resize further (prim size limits).");
        }
    }
}

// Apply the cached worn fit. Root-prim PRIM_POS_LOCAL/PRIM_ROT_LOCAL on
// an attachment are relative to the attach point; the rest of the
// linkset follows the root. Overrides the asset's baked attach offset.
apply_worn()
{
    llSetLinkPrimitiveParamsFast(LINK_THIS,
        [PRIM_POS_LOCAL, worn_pos, PRIM_ROT_LOCAL, worn_rot]);
}

open_menu(key who)
{
    llListenRemove(dlg_handle);
    dlg_channel = -100000 - (integer)llFrand(2000000000.0);
    dlg_handle = llListen(dlg_channel, "", who, "");
    dlg_deadline = llGetUnixTime() + 60;
    integer pct = llRound(current_factor() * 100.0);
    llDialog(who, llGetObjectName() + "\nCurrent size: " + (string)pct
        + "% of original.\n\nMenu edits last until the prop is re-rezzed"
        + " - use the furniture's ADJUSTMODE [SAVE] to keep them.",
        ["-1%", "-5%", "-10%", "+1%", "+5%", "+10%", "[RESTORE]", "[CLOSE]"],
        dlg_channel);
    // The menu timeout rides the 10 s watchdog tick (single timer for
    // both jobs - see timer()). Re-arming a running timer just resets
    // its phase, which is harmless here.
    llSetTimerEvent(10.0);
}

default
{
    state_entry()
    {
        // Parcel-accounting diet: without a limit every prop bills the
        // full 64 KB. The limit survives state changes. Tune in-world
        // if the dialog path ever hits a Stack-Heap Collision.
        llSetMemoryLimit(32768);
    }

    on_rez(integer start)
    {
        if (start)
        {
            state prop;
        }
    }
}

state prop
{
    state_entry()
    {
        if (llGetLinkNumber() < 2)
        {
            integer start = llGetStartParameter();
            if (start > 0)
            {
                // Wire v2 (see [QS]prop2 header): positive, bit-packed.
                prop_type    = start & 3;
                prop_point   = (start >> 2) & 63;
                prop_id      = (start >> 8) & 1023;
                comm_channel = -((start >> 18) & 8191);
            }
            else if (start <= -10000000)
            {
                // Stock decimal wire, digit-sliced like [AV]object.
                string sParam = (string)start;
                prop_type    = (integer)llGetSubString(sParam, -1, -1);
                prop_point   = (integer)llGetSubString(sParam, -3, -2);
                prop_id      = (integer)llGetSubString(sParam, -5, -4);
                comm_channel = (integer)llGetSubString(sParam, 0, -6);
            }
            if (comm_channel)
            {
                listen_handle = llListen(comm_channel, "", "", "");
                llSay(comm_channel, "REZ|" + (string)prop_id);
            }
        }

        // Click action, decided once (the merge removes the deferral
        // race between [AV]object and the companion):
        // types 1/2 touch-attach; world props without their own sitter
        // open the owner size menu (stock set CLICK_ACTION_NONE there).
        if (prop_type == 1 || prop_type == 2)
        {
            llSetClickAction(CLICK_ACTION_TOUCH);
        }
        else if (llGetInventoryType("[AV]sitA") == INVENTORY_NONE
            && llGetInventoryType("[QS]sitA") == INVENTORY_NONE)
        {
            llSetClickAction(CLICK_ACTION_TOUCH);
        }

        base_scale = llGetScale();
        worn_set = FALSE;  // stale cache guard on take-back + re-rez

        parentkey = llList2Key(llGetObjectDetails(llGetKey(), [OBJECT_REZZER_KEY]), 0);
        if (llGetStartParameter() && !llList2Integer(llGetObjectDetails(parentkey, [OBJECT_ATTACHED_POINT]), 0))
        {
            watchdog = TRUE;
            llSetTimerEvent(10);
        }
        else
        {
            watchdog = FALSE;
            llSetTimerEvent(0);
        }
    }

    attach(key id)
    {
        if (comm_channel)
        {
            if (llGetAttached())
            {
                llListen(local_attach_channel, "", "", "");
                llSay(comm_channel, "ATTACHED|" + (string)prop_id);
                llSay(local_attach_channel, "LOCAT|" + (string)llGetAttached());
                if (worn_set)
                {
                    // Persisted worn fit, cached from QSWORN in the REZ
                    // handshake (beats the experience-perm roundtrip).
                    apply_worn();
                }
                if (experience_denied_reason == 17)
                {
                    if (llGetOwner() == originalowner)
                    {
                        list details = llGetExperienceDetails("");
                        if (llList2String(details, 3) == "17")
                        {
                            llSay(comm_channel, "NAG|" + llList2String(details, 0));
                        }
                    }
                }
            }
            else
            {
                llSay(comm_channel, "DETACHED|" + (string)prop_id);
            }
        }
    }

    touch_start(integer touched)
    {
        if (llGetAttached()) return;
        if (prop_type == 1 || prop_type == 2)
        {
            llRequestExperiencePermissions(llDetectedKey(0), "");
            return;
        }
        // World prop: owner size menu ([QS]objectadjust merge).
        key who = llDetectedKey(0);
        if (who != llGetOwner()) return;
        open_menu(who);
    }

    run_time_permissions(integer permissions)
    {
        if (permissions & PERMISSION_ATTACH)
        {
            if (llGetAttached())
            {
                llDetachFromAvatar();
            }
            else
            {
                llAttachToAvatarTemp(prop_point);
            }
        }
        else
        {
            llSay(comm_channel, "DEREZ|" + (string)prop_id);
            llDie();
        }
    }

    experience_permissions(key target_id)
    {
        if (llGetAttached())
        {
            llDetachFromAvatar();
        }
        else
        {
            llAttachToAvatarTemp(prop_point);
        }
    }

    experience_permissions_denied(key agent_id, integer reason)
    {
        originalowner = llGetOwner();
        experience_denied_reason = reason;
        llRequestPermissions(agent_id, PERMISSION_ATTACH);
    }

    on_rez(integer start)
    {
        if (!llGetAttached())
        {
            state restart_prop;
        }
    }

    listen(integer channel, string name, key id, string message)
    {
        if (channel == dlg_channel)
        {
            // Owner size menu ([QS]objectadjust merge). Listen is
            // already filtered to the menu holder.
            if (message == "[CLOSE]")
            {
                llListenRemove(dlg_handle);
                dlg_handle = 0;
                if (!watchdog)
                {
                    llSetTimerEvent(0.0);
                }
                return;
            }
            if (message == "[RESTORE]")
            {
                scale_rel(1.0 / current_factor(), id);
            }
            else
            {
                float pct = (float)message;  // "+5%" -> 5.0, "-10%" -> -10.0
                if (pct != 0.0)
                {
                    scale_rel(1.0 + pct / 100.0, id);
                }
            }
            open_menu(id);  // re-open with updated percentage
            return;
        }
        if (channel == local_attach_channel)
        {
            // LOCAT from the wearer's other attachments (stock): the
            // newer attachment on our point evicts us. Cross-object by
            // design, so owner-scoped rather than parent-scoped.
            list d = llParseString2List(message, ["|"], []);
            if (llList2String(d, 0) == "LOCAT" && llGetOwnerKey(id) == llGetOwner() && llList2String(d, 1) == (string)llGetAttached())
            {
                llRequestPermissions(llGetOwner(), PERMISSION_ATTACH);
            }
            return;
        }

        // comm_channel. Everything below acts only for the furniture
        // that rezzed us - see from_parent(). Stock accepted these from
        // anyone on the (randomly rolled, collision-prone) channel.
        if (!from_parent(id)) return;

        list data = llParseString2List(message, ["|"], []);
        string command = llList2String(data, 0);
        if (command == "ATTACHTO" && prop_type == 1 && (key)llList2String(data, 2) == llGetKey())
        {
            if (llGetAgentSize((key)llList2String(data, 1)) == ZERO_VECTOR)
            {
                llSay(comm_channel, "DEREZ|" + (string)prop_id);
                llDie();
            }
            else
            {
                llRequestExperiencePermissions(llList2Key(data, 1), "");
            }
        }
        else if (llGetSubString(command, 0, 3) == "REM_")
        {
            integer remove;
            if (command == "REM_ALL")
            {
                remove = TRUE;
            }
            else if (command == "REM_INDEX" || (command == "REM_WORLD" && !llGetAttached()))
            {
                if (~llListFindList(data, [(string)prop_id]))
                {
                    remove = TRUE;
                }
            }
            else if (llGetAttached() && command == "REM_WORN" && (key)llList2String(data, 1) == llGetOwner())
            {
                remove = TRUE;
            }
            if (remove)
            {
                if (llGetAttached())
                {
                    llRequestPermissions(llGetOwner(), PERMISSION_ATTACH);
                }
                else
                {
                    if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) != ZERO_VECTOR)
                    {
                        unsit_all();
                        llSleep(1);
                    }
                    llSay(comm_channel, "DEREZ|" + (string)prop_id);
                    llDie();
                }
            }
        }
        else if (message == "PROPSEARCH")
        {
            // Stock SAVEPROP stays world-only (a furniture-relative
            // POSITION is meaningless worn); the scale factor is
            // well-defined either way, and the worn fit only worn.
            if (!llGetAttached())
            {
                llSay(comm_channel, "SAVEPROP|" + (string)prop_id);
            }
            llSay(comm_channel, "QSSAVESCALE|" + (string)prop_id
                + "|" + (string)current_factor());
            if (llGetAttached())
            {
                vector lp = llGetLocalPos();
                vector lr = llRot2Euler(llGetLocalRot()) * RAD_TO_DEG;
                llSay(comm_channel, "QSSAVEWORN|" + (string)prop_id
                    + "|" + (string)lp + "|" + (string)lr);
            }
        }
        else if (command == "QSSCALE")
        {
            if ((integer)llList2String(data, 1) == prop_id)
            {
                float f = (float)llList2String(data, 2);
                if (f > 0.0)
                {
                    scale_rel(f / current_factor(), NULL_KEY);
                }
            }
        }
        else if (command == "QSWORN")
        {
            if ((integer)llList2String(data, 1) == prop_id)
            {
                worn_pos = (vector)llList2String(data, 2);
                worn_rot = llEuler2Rot((vector)llList2String(data, 3) * DEG_TO_RAD);
                worn_set = TRUE;
                // Normally cached pre-attach (REZ handshake beats the
                // experience-perm roundtrip); apply late otherwise.
                if (llGetAttached())
                {
                    apply_worn();
                }
            }
        }
    }

    timer()
    {
        // Job 1: menu listen timeout ([QS]objectadjust merge).
        if (dlg_handle)
        {
            if (llGetUnixTime() > dlg_deadline)
            {
                llListenRemove(dlg_handle);
                dlg_handle = 0;
            }
        }
        // Job 2: orphan watchdog (stock) - furniture gone, so leave.
        if (watchdog)
        {
            if (llGetObjectMass(parentkey) == 0)
            {
                if (!llGetAttached())
                {
                    llDie();
                }
                else
                {
                    llRequestPermissions(llGetOwner(), PERMISSION_ATTACH);
                }
            }
        }
        else
        {
            if (!dlg_handle)
            {
                // Neither job pending - stop ticking.
                llSetTimerEvent(0.0);
            }
        }
    }
}

state restart_prop
{
    state_entry()
    {
        state prop;
    }
}
