string version = "0.9";
/*
 * [QS]rezzerProbe - throwaway measurement probe, NOT a shipping script
 *
 * Answers two questions the prop wire hardening depends on
 * (qs/plugins/prop2/, see PROTOCOL.md § Prop wire v2):
 *
 *  1. Does OBJECT_REZZER_KEY of a rezzed prop equal the FURNITURE ROOT
 *     key (what [QS]object's from_parent() assumes), or the key of the
 *     prim holding the rezzing script?
 *  2. Does the value survive attachment, or fall to NULL_KEY? (Decides
 *     whether [QS]prop2 can rezzer-scope replies from WORN props -
 *     "Schicht 3" - or must fall back to owner-vs-sitter scoping.)
 *
 * Use: drop into a test prop's root prim NEXT TO [QS]object, trigger
 * the pose so the furniture rezzes it, let a type-1 attach happen,
 * then read the owner chat: one line per event, each showing rezzer
 * key, own root key and attach point. Compare the rezzer key against
 * the furniture root key (edit window, or [QS]debug). Remove the
 * script after the measurement.
 */

say(string tag)
{
    llOwnerSay("[rezzerProbe] " + tag
        + " | rezzer=" + (string)llList2Key(
            llGetObjectDetails(llGetKey(), [OBJECT_REZZER_KEY]), 0)
        + " | own_root=" + (string)llList2Key(
            llGetObjectDetails(llGetKey(), [OBJECT_ROOT]), 0)
        + " | attached=" + (string)llGetAttached());
}

default
{
    state_entry()
    {
        say("state_entry");
    }

    on_rez(integer start)
    {
        say("on_rez start=" + (string)start);
    }

    attach(key id)
    {
        say("attach id=" + (string)id);
    }

    touch_start(integer touched)
    {
        // Manual re-read at any time.
        say("touch");
    }
}
