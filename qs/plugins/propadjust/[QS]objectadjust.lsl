/*
 * [QS]objectadjust - optional prop-side companion for live prop scaling
 *
 * Named after the stock [AV]object script it ships beside. Open like the
 * rest of the sitter: the receiving side is [QS]prop >= 1.25 and the wire
 * spec lives in qs/PROTOCOL.md § Prop scale.
 *
 * Ships INSIDE a prop object, in the ROOT prim, next to the stock
 * [AV]object script. [AV]object must stay untouched (it is compiled
 * under the AVsitter experience; a source fork loses the no-dialog
 * temp-attach). This script is therefore fully self-contained: it
 * decodes the same llGetStartParameter() encoding that stock [AV]prop
 * and [QS]prop use at llRezAtRoot time:
 *
 *   start_param = comm_channel * 100000 - (index*1000 + point*10 + type)
 *
 * Wire — all region-say on comm_channel:
 *   QSSCALE|<id>|<factor>      [QS]prop → prop : apply persisted factor
 *   QSWORN|<id>|<pos>|<rot>    [QS]prop → prop : cache persisted worn fit
 *                              (local pos + Euler-deg rot vs attach point),
 *                              applied in the attach() event
 *   PROPSEARCH                 [QS]prop → props: stock [SAVE] broadcast
 *   QSSAVESCALE|<id>|<factor>  prop → [QS]prop : report current factor
 *   QSSAVEWORN|<id>|<pos>|<rot> prop → [QS]prop: report current worn fit
 *                              (only sent while attached)
 *
 * <factor> is always relative to the prop's INVENTORY scale (the root
 * scale at rez, captured before QSSCALE arrives). Viewer-editor stretch
 * and the touch menu below both end up in the same llGetScale()-derived
 * factor, so the furniture-side [SAVE] persists either kind of edit.
 * Uniform scaling only (llScaleByFactor) — per-axis stretch of the
 * linkset is not representable and gets flattened to the X-axis ratio.
 *
 * Touch menu (furniture owner, world-rezzed type-0/3 props only):
 * ±1/5/10 % presets + [RESTORE] back to inventory size — end-user
 * fine-adjust without opening the editor. Menu edits are per-rez
 * unless the owner persists them via ADJUSTMODE [SAVE].
 *
 * Stock compatibility: under stock [AV]prop the QSSCALE command never
 * arrives and the QSSAVESCALE reply is ignored — the prop just behaves
 * as if unscaled. A prop without this script ignores QSSCALE likewise.
 */
string version = "1.25";

integer comm_channel;
integer prop_id;
integer prop_type;

vector  base_scale;     // root scale at rez = inventory scale (factor 1.0)
integer worn_set;       // TRUE once QSWORN delivered a persisted fit
vector  worn_pos;       // local pos vs attach point
rotation worn_rot;      // local rot vs attach point
integer dlg_channel;
integer dlg_handle;
integer click_pending;  // one-shot init timer pending (see timer())

float current_factor()
{
    // LSL forbids member access on a call result (llGetScale().x) —
    // store the vector first.
    vector cur = llGetScale();
    return cur.x / base_scale.x;
}

// Scale the whole linkset by rel (relative to CURRENT size), clamped to
// what llScaleByFactor allows. `who` gets a chat note on hard failure
// (NULL_KEY = silent, used for the rez-time QSSCALE apply).
scale_rel(float rel, key who)
{
    // stay slightly within the reported limits — exact values fail on
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
    integer pct = llRound(current_factor() * 100.0);
    llDialog(who, llGetObjectName() + "\nCurrent size: " + (string)pct
        + "% of original.\n\nMenu edits last until the prop is re-rezzed"
        + " — use the furniture's ADJUSTMODE [SAVE] to keep them.",
        ["-1%", "-5%", "-10%", "+1%", "+5%", "+10%", "[RESTORE]", "[CLOSE]"],
        dlg_channel);
    llSetTimerEvent(60.0);  // menu listen timeout
}

default
{
    state_entry()
    {
        // Passive until rezzed by [QS]prop / [AV]prop with a start
        // parameter (creator adding the script to an unrezzed or
        // manually rezzed prop lands here and stays quiet).
    }

    on_rez(integer start)
    {
        if (start <= -10000000)
        {
            state active;
        }
    }
}

state active
{
    state_entry()
    {
        // Same digit-slicing as stock [AV]object.
        string sParam = (string)llGetStartParameter();
        prop_type    = (integer)llGetSubString(sParam, -1, -1);
        prop_id      = (integer)llGetSubString(sParam, -5, -4);
        comm_channel = (integer)llGetSubString(sParam, 0, -6);
        base_scale   = llGetScale();
        worn_set     = FALSE;  // stale cache guard on take-back + re-rez
        llListen(comm_channel, "", "", "");
        // Defer llSetClickAction so [AV]object's own state_entry (which
        // may set CLICK_ACTION_NONE) has run first — otherwise the
        // outcome of the two writes is a race.
        click_pending = TRUE;
        llSetTimerEvent(2.0);
    }

    on_rez(integer start)
    {
        // Re-rezzed: bounce through a helper state so state_entry runs
        // again with the fresh start parameter (new channel, new base).
        if (start <= -10000000)
        {
            state rebound;
        }
        else
        {
            state default;
        }
    }

    attach(key av)
    {
        if (av != NULL_KEY)
        {
            if (worn_set)
            {
                apply_worn();
            }
        }
    }

    touch_start(integer touched)
    {
        if (llGetAttached()) return;
        // Types 1/2: [AV]object owns touch (touch-to-attach).
        if (prop_type == 1 || prop_type == 2) return;
        key who = llDetectedKey(0);
        if (who != llGetOwner()) return;
        open_menu(who);
    }

    listen(integer channel, string name, key id, string message)
    {
        if (channel == comm_channel)
        {
            list data = llParseString2List(message, ["|"], []);
            string cmd = llList2String(data, 0);
            if (cmd == "QSSCALE")
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
            else if (cmd == "QSWORN")
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
            else if (message == "PROPSEARCH")
            {
                // Unlike stock [AV]object's SAVEPROP (world-only — a
                // furniture-relative POSITION is meaningless worn), the
                // scale factor stays well-defined on an attached prop, so
                // we answer worn too: lets type-1 auto-attach props be
                // resized on-body in the editor and saved via [SAVE].
                llSay(comm_channel, "QSSAVESCALE|" + (string)prop_id
                    + "|" + (string)current_factor());
                if (llGetAttached())
                {
                    // Worn fit: local pos/rot vs attach point, editable
                    // on-body in the viewer editor.
                    vector lp = llGetLocalPos();
                    vector lr = llRot2Euler(llGetLocalRot()) * RAD_TO_DEG;
                    llSay(comm_channel, "QSSAVEWORN|" + (string)prop_id
                        + "|" + (string)lp + "|" + (string)lr);
                }
            }
            return;
        }
        // dialog channel
        if (message == "[CLOSE]")
        {
            llListenRemove(dlg_handle);
            llSetTimerEvent(0.0);
            return;
        }
        if (message == "[RESTORE]")
        {
            scale_rel(1.0 / current_factor(), id);
        }
        else
        {
            float pct = (float)message;  // "+5%" → 5.0, "-10%" → -10.0
            if (pct != 0.0)
            {
                scale_rel(1.0 + pct / 100.0, id);
            }
        }
        open_menu(id);  // re-open with updated percentage
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (click_pending)
        {
            click_pending = FALSE;
            // Left-click opens our menu on plain ground props only. Skip
            // sittable props ([AV]object leaves the sit cursor there) and
            // attach-types (touch = attach).
            if (prop_type != 1 && prop_type != 2)
            {
                integer has_sitter = FALSE;
                if (llGetInventoryType("[AV]sitA") != INVENTORY_NONE) has_sitter = TRUE;
                if (llGetInventoryType("[QS]sitA") != INVENTORY_NONE) has_sitter = TRUE;
                if (!has_sitter)
                {
                    if (!llGetAttached())
                    {
                        llSetClickAction(CLICK_ACTION_TOUCH);
                    }
                }
            }
            return;
        }
        llListenRemove(dlg_handle);  // menu timeout
    }
}

state rebound
{
    state_entry()
    {
        state active;
    }
}
