/*
 * [QS]plugin-example — minimal QSPLUG_REGISTER reference implementation
 *
 * Drop into a QuickySitter furniture. Registers one button into the
 * [OPTIONS] top-level menu (rendered by [QS]sitB ≥ 0.910). Clicking
 * the button llRegionSayTo's the controller for visual confirmation.
 *
 * Multi-copy and rename to exercise sitB's paging + dedupe semantics:
 *   [QS]plugin-example alpha
 *   [QS]plugin-example beta
 *   [QS]plugin-example gamma
 *   ...
 * (dedupe is by llGetScriptName, so renamed copies coexist.)
 *
 * Spec:    qs/PROTOCOL.md § QSPLUG_REGISTER
 * Channel: 90212 (plugin → sitB)
 * License: MPL 2.0 — same as the rest of the fork.
 */

// Channel sitB listens on for plugin registrations.
integer QSPLUG_REGISTER = 90212;

// QSALIVE reply broadcast. sitA slot 0 emits this unsolicited on its
// state_entry; we use that as the cheapest "sitter pack reset, re-announce"
// trigger. See QSALIVE Discovery in the docs.
integer QSALIVE_REPLY   = 90097;

// Pick a free channel for your click events. Fork-reserved bands leave
// 90212-90229 and 90232-90259 free; pick anything in there that isn't
// already taken by another plugin. Document your pick — collisions are
// silent dispatch corruption.
integer MY_CLICK_CHAN   = 90234;

// Button label shown in the [OPTIONS] dialog. Bracket-wrapped uppercase
// is the convention but not required.
string  MY_LABEL        = "[EXAMPLE]";

register_button()
{
    // PROTOCOL: "<label>|<click_chan>|<scriptName>"
    // Dedupe key is scriptName: a re-announce on plugin reset /
    // inventory change overwrites the existing slot in sitB's registry
    // instead of appending a duplicate. id is reserved (empty).
    llMessageLinked(LINK_SET, QSPLUG_REGISTER,
        MY_LABEL + "|" + (string)MY_CLICK_CHAN + "|" + llGetScriptName(),
        "");
}

default
{
    state_entry()
    {
        register_button();
        llOwnerSay(llGetScriptName() + " ready (channel "
            + (string)MY_CLICK_CHAN + ")");
    }

    on_rez(integer p)
    {
        // Furniture rezzed into a new region or after take-into-inventory.
        // Cheapest re-sync: re-announce so sitB's registry has us even
        // if it was wiped by a full sitter pack reset.
        register_button();
    }

    changed(integer c)
    {
        if (c & CHANGED_INVENTORY)
        {
            // Our own script may have been renamed by the creator (drag-
            // rename in inventory). scriptName changing means dedupe key
            // changes, so sitB would otherwise keep our old entry as a
            // ghost. Cheapest fix: re-announce; the dedupe loop in sitB
            // does the rest.
            register_button();
        }
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        // sitA broadcasts QSALIVE_REPLY unsolicited on its state_entry.
        // If sitA reset while we kept running, sitB likely also re-loaded
        // (boot's QS_BOOT_RELOAD cascade) and the registry is empty.
        // Re-announce; idempotent if sitB still has us.
        if (num == QSALIVE_REPLY)
        {
            register_button();
            return;
        }
        // Our click event. msg = the label sitB rendered (matches MY_LABEL).
        // id = controller key — the avatar who picked the button in the
        // [OPTIONS] dialog.
        if (num == MY_CLICK_CHAN)
        {
            llRegionSayTo(id, 0, llGetScriptName()
                + " clicked by " + llKey2Name(id)
                + " on " + llGetObjectName() + ".");
            return;
        }
    }
}
