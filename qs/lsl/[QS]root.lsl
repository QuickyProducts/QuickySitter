/*
 * [QS]root - QuickySitter root-prim touch forwarder
 *
 * Fork of [AV]root from AVsitter2 (MPL 2.0). The only functional
 * change is replacing the hard-coded "[AV]sitA" reference with
 * "[QS]sitA"; everything else is verbatim.
 *
 * Why fork: stock [AV]root checks llGetInventoryType("[AV]sitA")
 * to decide whether to forward touches from a non-sitter root prim
 * to child sitter prims. With QuickySitter scripts renamed to
 * [QS]sitA, the stock check always reports "not present" and
 * [AV]root forwards even when sitA is sitting right next to it,
 * causing duplicated 90005 menu requests.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */
//string #version = "0.01";
string script_basename = "[QS]sitA";
string menu_script = "[AV]menu";
key A;
list B = [A]; //OSS::list B; // Force error in LSO

default
{
    touch_end(integer touched)
    {
        if (llGetInventoryType(script_basename) != INVENTORY_SCRIPT && llGetInventoryType(menu_script) != INVENTORY_SCRIPT)
        {
            llMessageLinked(LINK_ALL_OTHERS, 90005, llList2String(B, 0), llDetectedKey(0));
            B = [];
        }
    }
}
