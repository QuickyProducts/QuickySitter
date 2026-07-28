/*
 * [QS]anim - QuickySitter v2 animation holder
 *
 * One instance per seat, and the ONLY script in v2 that is instantiated
 * per seat. It exists for a single reason: a script can hold
 * PERMISSION_TRIGGER_ANIMATION for exactly one avatar at a time
 * (llGetPermissionsKey() is single-valued), so N simultaneous occupants
 * need N permission holders. Everything else the old [QS]sitA did lives
 * in the [QS]core / [QS]seat singletons.
 *
 * See qs2/DESIGN.md §3 for why permission cycling in a single script was
 * rejected, and §6.4 for the split.
 *
 * ANONYMOUS AND INTERCHANGEABLE. This script has no seat index and no
 * name suffix. It reports llGetScriptName() as its handle and [QS]seat
 * assigns it a seat at runtime. Permission binds to the avatar, not to
 * the prim, so every animator can sit in the same prim as the animations
 * regardless of which prim its occupant is sitting on — which is exactly
 * what the shipping [QS]sitA instances already do today.
 *
 * The creator drops N identical copies in. There is nothing to rename.
 *
 * WIRE (provisional, 904xx block — not yet reserved in PROTOCOL.md)
 *
 *   90400  QSA_CENSUS   seat→all    ""                   re-announce
 *   90401  QSA_HELLO    anim→seat   msg = handle          "I exist and am idle"
 *   90402  QSA_BIND     seat→anim   msg = handle          take permission for
 *                                   id  = avatar          this avatar
 *   90403  QSA_READY    anim→seat   msg = handle          permission landed
 *                                   id  = avatar
 *   90404  QSA_PLAY     seat→all    msg = "h=anim|h=anim" start these animations
 *   90405  QSA_RELEASE  seat→anim   msg = handle          stop and go idle
 *
 * QSA_PLAY is deliberately ONE broadcast carrying every participating
 * animator's assignment, rather than one addressed message each. All
 * animators receive it in the same sim frame and already hold their
 * permission, so they call llStartAnimation in the same frame. That is
 * what keeps SYNC couple poses in step, and it is bit-for-bit the
 * property today's per-seat sitA instances have.
 *
 * Ordering contract with [QS]seat: BIND, then READY, then PLAY. A PLAY
 * arriving before permission has landed is dropped, not queued.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.01";

integer QSA_CENSUS  = 90400;
integer QSA_HELLO   = 90401;
integer QSA_BIND    = 90402;
integer QSA_READY   = 90403;
integer QSA_PLAY    = 90404;
integer QSA_RELEASE = 90405;

string  HANDLE;          // llGetScriptName(); our identity on the wire
string  CURRENT;         // animation currently playing; "" when none

integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(HANDLE + "[" + version + "] " + s);
}

// [QS]seat builds its animator table from these. We are interchangeable,
// so the handle is the only thing worth reporting: no seat, no index, no
// capabilities. Announced at state_entry and re-announced on census, the
// same announce-don't-probe rule the plugins follow (DESIGN.md §7.3).
announce()
{
    llMessageLinked(LINK_SET, QSA_HELLO, HANDLE, "");
}

// Swap the running animation.
//
// Order is taken from [QS]sitA and matters: start the new animation
// FIRST, then stop the old one a moment later. Stopping first leaves the
// avatar in its default pose for a frame, which reads as a visible twitch
// on every pose change.
play(string anim)
{
    if (anim == CURRENT) return;
    if (!(llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)) return;

    string old = CURRENT;
    CURRENT = anim;

    if (anim != "") llStartAnimation(anim);
    if (old != "")
    {
        if (anim != "") llSleep(0.2);   // overlap, not a delay: the new one is already running
        llStopAnimation(old);
    }
}

// Standing up revokes permission by itself and stops the animation with
// it, so in that path this is pure bookkeeping. The explicit stop matters
// for the other path, where [QS]seat releases us while the avatar is
// still seated (a swap, or a seat being taken over).
release()
{
    if (CURRENT != "")
    {
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
            llStopAnimation(CURRENT);
        CURRENT = "";
    }
}

default
{
    state_entry()
    {
        HANDLE = llGetScriptName();

        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;

        announce();

        // SIZING LINE. Unconditional on purpose while DESIGN.md open
        // question 1 is open: this script's real byte cost is the one
        // estimate that gets multiplied by the seat count. Drop it in a
        // prim and read the number; nothing else has to work for that.
        // Demote to Out(1, ...) — matching sitA's "Ready, Mem=" line —
        // before this ships.
        llOwnerSay(HANDLE + "[" + version + "] ready"
            + ", used=" + (string)llGetUsedMemory()
            + ", free=" + (string)llGetFreeMemory());

        // llSetMemoryLimit is deliberately NOT set yet. The whole memory
        // case rests on it (DESIGN.md §2, open question 2), but the limit
        // has to come from a measured worst case plus headroom, not from
        // a guess — a limit set to the boot figure collides with the heap
        // later, under load.
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSA_PLAY)
        {
            // Pick our own assignment out of "handle=anim|handle=anim|…".
            // Parsing costs microseconds and happens in the same frame for
            // everybody, so it does not disturb the sync property.
            list rows = llParseString2List(msg, ["|"], []);
            integer i = llGetListLength(rows);
            while (i--)
            {
                string row = llList2String(rows, i);
                integer cut = llSubStringIndex(row, "=");
                if (cut > 0)
                {
                    // Nested rather than && : LSL evaluates both operands
                    // of && always, so a guard has to be its own statement.
                    if (llGetSubString(row, 0, cut - 1) == HANDLE)
                    {
                        play(llGetSubString(row, cut + 1, -1));
                        return;
                    }
                }
            }
            return;
        }

        if (num == QSA_BIND)
        {
            if (msg != HANDLE) return;
            // Auto-granted without a dialog for an avatar already sitting
            // on this object. The grant arrives as run_time_permissions,
            // which is why BIND and PLAY are separate steps.
            llRequestPermissions(id, PERMISSION_TRIGGER_ANIMATION);
            return;
        }

        if (num == QSA_RELEASE)
        {
            if (msg != HANDLE) return;
            release();
            return;
        }

        if (num == QSA_CENSUS)
        {
            announce();
            return;
        }
    }

    run_time_permissions(integer perm)
    {
        if (perm & PERMISSION_TRIGGER_ANIMATION)
        {
            // Report llGetPermissionsKey() rather than the key we were
            // handed: if two binds raced, this is the one that actually
            // landed, and [QS]seat needs to know which.
            llMessageLinked(LINK_SET, QSA_READY, HANDLE, llGetPermissionsKey());
        }
    }
}
