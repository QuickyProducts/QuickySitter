/*
 * wiretap - throwaway link-message sniffer for the v2 bring-up
 *
 * Drop it into the SAME PRIM as the base set, press one HUD arrow, and
 * paste what it says. It answers the only question left about the HUD
 * adjust path: how far along the chain does a button press actually get?
 *
 * The expected chain for one arrow press, ADJUSTMODE On:
 *
 *   (HUD chats to hudproxy on a per-sitter channel - NOT visible here,
 *    it is region chat, not a link message)
 *   90301  hudproxy -> core     msg=<slot>  id=<name>|<pos>|<rot>|
 *   90055  core     -> adjuster msg=<slot>  id=<name>|<anim>|<pos>|<rot>|..
 *   90421  core     -> seat     msg=<slot>=<anim>=<pos>=<rot>
 *
 * ADJUSTMODE Off instead:
 *
 *   90262  hudproxy -> offset   (needs [QS]offset present, or hudproxy
 *                                bails before sending ANYTHING)
 *   90057  hudproxy -> seat     msg=<slot>  id=<absPos>|<absRot>|
 *
 * READING THE SILENCE IS THE POINT:
 *   nothing at all      -> the press never reached hudproxy. Look at the
 *                          HUD side: 90060 must have opened the listen,
 *                          and qs:hud:admin_alive must be "1".
 *   90301 but no 90055  -> core rejected it. Almost certainly the
 *                          qs:cur match: the seat is not playing the
 *                          pose the HUD thinks it is.
 *   90055 but no 90421  -> impossible, they are consecutive statements.
 *   90421 but no motion -> seat has no prim bound to that slot.
 *
 * Delete it again afterwards. It is 64 KB of region script memory that
 * does nothing but talk.
 */

// Numbers worth naming; anything else is printed raw.
list WATCH = [
    90045, "POSEPLAYED   core->all",
    90055, "ANIMINFO     core->hud/adj",
    90057, "HELPERMOVED  hud->seat",
    90060, "NEWSITTER    seat->all",
    90065, "SITTERGONE   seat->all",
    90070, "SITTERSUPD   seat->hud",
    90261, "POSECHANGED  hudproxy->hudadmin",
    90262, "OFFSETSAVE   hud->offset",
    90266, "ADJUSTMODE   toggle",
    90271, "RESYNC",
    90280, "PROPATTACH   hudadmin->prop",
    90301, "POSESAVED    hud/adj->core",
    90421, "QSC_APPLY    core->seat",
    90430, "QSB_READY    boot->base"
];

default
{
    state_entry()
    {
        llOwnerSay("wiretap listening. Press ONE arrow, then paste.");
        llOwnerSay("ADJUSTMODE = '"
            + llLinksetDataRead("QPP_CFG:ADJUSTMODE") + "'  (empty = never set)");
        llOwnerSay("qs:hud:admin_alive = '"
            + llLinksetDataRead("qs:hud:admin_alive") + "'");
        llOwnerSay("qs:alive:offset = '"
            + llLinksetDataRead("qs:offset:alive") + "'  (empty = [QS]offset absent,"
            + " which silently kills the ADJUSTMODE-Off path)");
        integer c = 0;
        string seats;
        while (llLinksetDataRead("qs:sitter:" + (string)c) != "")
        {
            seats += " " + (string)c + ":cur='"
                + llLinksetDataRead("qs:cur:" + (string)c) + "'";
            ++c;
        }
        llOwnerSay("seats" + seats);
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        integer at = llListFindList(WATCH, [num]);
        string tag = "";
        if (at != -1) tag = " " + llList2String(WATCH, at + 1);
        llOwnerSay("<" + (string)sender + "> " + (string)num + tag
            + "  msg=[" + msg + "]  id=[" + (string)id + "]");
    }
}
