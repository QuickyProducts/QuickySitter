# QuickySitter — Testplan: Sync-Drift Investigation

## Zweck

Multi-Sitter-SYNC-Posen driften zwischen Viewern auseinander, besonders
nach Camera-Operationen (Zoom raus/zurück) und anderen Events, die einen
Avatar temporär aus der Interest-List fallen lassen. Dieser Testplan
deckt Diagnose und spätere Verifikation einer Re-Sync-Lösung ab.

**Mechanismus:** Fällt ein Avatar aus dem Cull, requested der Viewer
beim Wiederkommen den Anim-State neu und startet die Loop lokal bei
`t=0`. Andere Viewer behalten ihre Timeline → Drift. Ein einzelner
Script-Restart bringt nur die Viewer wieder in Phase, die das
Restart-Signal im selben Frame empfangen — der gerade aus dem Cull
zurückkommende Viewer driftet weiter, bis das nächste koordinierte
Re-Sync-Signal kommt.

**SYNC in QuickySitter:** POSE-Posen werden als `P:<name>` gespeichert,
SYNC-Posen ohne Prefix. `[QS]sitA.lsl` broadcastet das `IS_SYNC`-Flag via
LinkMsg 90045; `[QS]sitB.lsl` nutzte es bisher nur für den
SYNC-Konflikt-Reset auf `FIRST_INDEX`.

Mit `[QS]sitA` ≥ 0.22 nimmt sitA zusätzlich LinkMsg **90271** entgegen,
um auf Anforderung einen Stop+Start-Cycle der Hauptpose zu fahren.
Policy (auto-Tick, manual, Frequenz) liegt **nicht** in sitA, sondern
beim Sender — typischerweise hudproxy aus dem QuickyHUD-Repo. Siehe
[`PROTOCOL.md` § Re-Sync trigger](./PROTOCOL.md#re-sync-trigger--90271).

---

## A. Single-Sitter Pose-Lifecycle

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-001 | Normaler Posewechsel | niedrig | Switch ohne Lücken-Frame | keine T-Pose zwischen alt/neu; `llGetAnimationList` enthält neue Anim ≤1 s | nein |
| TC-002 | 5 Posewechsel in <2 s | mittel | letzter Klick gewinnt | `llGetAnimationList` nach 1 s = letzte Anfrage; keine Anims aus verworfenen Klicks aktiv | evtl |
| TC-010 | Non-loop Animation endet | mittel | definierter Übergang | sitA-`timer` feuert; `OLD_ANIMATION_FILENAME` gestoppt | ja |
| TC-014 | 20 Posewechsel in Folge | hoch | keine Race-Condition | finale Pose match; keine Ghost-Einträge in `llGetAnimationList` | ja |
| TC-015 | Unsit während Posewechsel | mittel | sauberer Cleanup | `release_sitter` ruft `llStopAnimation`; `MY_SITTER == ""` nach 1 s | nein |

## B. Multi-Sitter SYNC (Kern-Thema)

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-012 | 2 Sitter, FPS 60 vs FPS 15, SYNC-Pose | hoch | kein sichtbarer Drift | Phasen-Offset <200 ms über 5 min | ja |
| TC-021 | Avatar zoomt aus Draw-Distance raus & zurück | hoch | nach Re-Acquisition synchron | Phasen-Offset <200 ms, 30 s nach Wiedereintritt | ja |
| TC-022 | SYNC-Pose 20-min-Dauerlauf, 2 Sitter | hoch | kein akkumulierter Drift | Drift-Rate <25 ms/min (lineare Regression) | ja |
| TC-023 | Re-Sync triggert während Sequence-Frame-Wechsel | mittel | kein Doppel-Restart | `SEQUENCE_POINTER` korrekt; keine T-Pose-Frames | nein |
| TC-024 | Sync-Konflikt: 2 Sitter starten dieselbe SYNC zeitversetzt | mittel | OLD_SYNC-Reset (90045) | sitB setzt `ANIM_INDEX = FIRST_INDEX` | nein |
| TC-026 | 2×2 Sitter, 2 verschiedene SYNC-Posen parallel | mittel | beide Gruppen unabhängig synchron | innerhalb Gruppe <200 ms; keine Quer-Beeinflussung | ja |

## C. AO / Animation-Konflikte

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-003 | AO aktiv (Idle/Walk), Bento-Body-Pose | hoch | Pose dominiert in den belegten Bone-Slots | Pose-Anim in `llGetAnimationList`; visuell keine AO-Bewegung in Pose-Slots | ja |
| TC-004 | AO während Pose toggle (an/aus/an) | hoch | kein Drift, kein Position-Snap | Phasen-stabil; Avatar-Position ±5 cm konstant | ja |
| TC-017 | Bento-Pose + Bento-Hand-AO | hoch | Hände bleiben pose-gesteuert | Hand-Anim der Pose in `llGetAnimationList`, nicht AO-Hand | ja |

## D. Netzwerk / Region

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-005 | Viewer-Lag (>1 s Stutter) | hoch | Pose startet verzögert, korrekt | nach Lag korrekt; Recovery <5 s | ja |
| TC-007 | Teleport sitzend | kritisch | Sit-Status + Pose erhalten | `MY_SITTER` unverändert; Anim läuft weiter; kein Unsit | ja |
| TC-008 | Region-Crossing sitzend | kritisch | Position stabil, Pose läuft | KFM-pause/play greift; Positionssprung <0.5 m | ja |
| TC-011 | Netzwerk-Drop 5–10 s | kritisch | automatische Recovery | Pose nach Reconnect <10 s synchron | ja |
| TC-013 | Sim-Lag >0.5 s/Frame | hoch | Queue stabil | letzte Anfrage angekommen; `MENU_LIST` intakt | ja |
| TC-020 | Region-Restart, Sitter persistiert nicht | kritisch | nach Re-Sit Default-Pose aus LSD | LSD-Persistenz greift; `boot_done == TRUE` vor erstem Sit | ja (manuell) |

## E. Avatar-Lifecycle

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-016 | 10× Sitzen/Unsitzen | mittel | keine Ghost-States | keine doppelten Listener; `MY_SITTER` sauber | nein |
| TC-018a | Outfit-Replace, kein Sitter-Detach | hoch | Pose-Anim läuft weiter | `llGetAnimationList` stabil | nein |
| TC-018b | Outfit-Add (Layer) | niedrig | keine Wirkung erwartet | Pose unverändert | nein |
| TC-019 | Avatar-Rebake | hoch | Pose bleibt aktiv | `llGetAnimationList` stabil über Rebake | nein |

## F. State-Recovery

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-006 | Anim-Asset nicht im Viewer-Cache | hoch | Nachladen, dann korrekt | initial 1–3 s evtl T-Pose; danach korrekt | ja |
| TC-009a | `[QS]root.lsl` Reset | kritisch | aus LSD rekonstruierbar | aktive Sitter bleiben gesittet; LSD-Re-Init | ja |
| TC-009b | `[QS]sitA.lsl` Reset | kritisch | per-Sitter-State aus Boot | Re-Init via 90098; `MY_SITTER` aus Sit-Status | ja |
| TC-009c | `[QS]sitB.lsl` Reset | kritisch | `MENU_LIST` aus Boot rekonstruiert | Re-Init via 90098; `FIRST_INDEX`-Pose | ja |

## G. Neue Coverage

| ID | Szenario | Risiko | Erwartetes Ergebnis | Mess-/Pass-Kriterium | Recovery |
|---|---|---|---|---|---|
| TC-025 | Sitter denied `PERMISSION_TRIGGER_ANIMATION` | mittel | Pose stoppt, kein Hang | sitA gibt Sitter frei; `MY_SITTER == ""` | nein |
| TC-027 | Sit während Boot-Race (90098-Stream aktiv) | mittel | Pose-Default greift nach Boot | `boot_done == TRUE` vor erster Anim; kein verlorener Sit | ja |
| TC-028 | `[QS]hudprop` Auto-Attach bei Sit | mittel | HUD-Prop + Pose laufen | **deferred** — wartet auf QSALIVE LINK_SET-Layer (siehe MEMORY) | ja |
| TC-029 | ~~Dummy-Anim-Refresh-Trick~~ Multi-Avatar-Test in 0.18/0.19: refresht Skeleton, **nicht** Loop-Phase. Verworfen. | — | n/a | siehe Iterations-History unten | n/a |
| TC-030 | hudproxy sendet 90271 bei aktivem Multi-Avatar-Setup | hoch | beide Sitter visuell gesynct nach 1 Tick | Phasen-Offset <200 ms 5 s nach Trigger; kein „stand-up"-Flackern | ja |
| TC-031 | 90271 auf POSE-Pose (P:-Prefix) | niedrig | no-op, kein Stop+Start | `do_resync_tick` returned früh; Pose unverändert | n/a |
| TC-032 | 90271 ohne Sitter | niedrig | no-op | early return wegen `llGetAgentSize == ZERO_VECTOR` | n/a |

---

## Mess-Methodik

- **Phasen-Offset.** Zwei Avatare in selber SYNC-Pose nebeneinander,
  externe Bildschirmaufnahme mit Frame-Counter. Offset = Frame-Differenz
  bei identischer Pose-Phase / FPS. „Synchron" = <200 ms (≈ 6 Frames @
  30 fps).
- **Drift-Rate.** Phasen-Offset alle 60 s über 20 min loggen → lineare
  Regression. „Kein akkumulierter Drift" = <25 ms/min.
- **Pose-Switch-Latenz.** UI-Klick-Timestamp bis `llGetAnimationList`
  neue Anim enthält. Toleranz <1 s.
- **State-Recovery-Zeit.** Event bis Pose wieder korrekt. <5 s
  (TC-005/006/011), <10 s (TC-008/020).
- **State-Inspektion.** `[QS]debug.lsl`-Dump als Ground Truth für
  LSD/`MENU_LIST`/`SITTERS`.
- **Visuelle Stabilität.** Frame-by-Frame-Review der Aufnahme — keine
  T-Pose-Frames zulässig außer wo explizit erwartet (TC-006).

---

## Design-Entscheidungen (Re-Sync-Implementierung)

Endmodell: **HUD owns policy, sitA owns mechanism.** sitA stellt einen
einzigen LinkMsg-Trigger (90271) bereit; alle Entscheidungen über
*wann*, *wie oft*, *automatisch oder manuell* treffen Sender —
typischerweise hudproxy aus dem QuickyHUD-Repo. Implementierungs-
Referenzen: [`PROTOCOL.md` § Re-Sync trigger](./PROTOCOL.md#re-sync-trigger--90271)
und [`[QS]sitA.lsl`](./[QS]sitA.lsl) `do_resync_tick()`.

### Mechanismus

`do_resync_tick()` macht nichts außer einem `Stop`-`Sleep(0.05)`-`Start`-
Cycle der laufenden Hauptpose, gegated auf vier Conditions:

- aktuelle Pose ist eine SYNC-Pose (kein `P:`-Prefix)
- `PERMISSION_TRIGGER_ANIMATION` vorhanden
- Sitter ist alive (`llGetAgentSize != ZERO_VECTOR`)
- `CURRENT_ANIMATION_FILENAME` nicht leer

Der 50-ms-Sleep ist ≥ 1 Sim-Frame (Sim ~45 Hz) gegen Coalescing,
< 1 Viewer-Render-Frame bei 30 FPS, um den Gap nicht sichtbar zu
machen. Das ist die einzige Mechanik, die echt eine Loop-Phase auf
allen Viewern resettet — Loop-Phase ist viewer-lokal beim `Start`-
Event determiniert.

### Iterations-History (sitA 0.16-0.21, alle verworfen)

Vor 0.22 hatte sitA verschiedene Auto-Tick-Architekturen, die alle
verworfen wurden:

- **0.16:** naives Stop+Start der Hauptanim, 30-s-Wall-Clock-Timer,
  300 ms Sleep. Sync funktioniert, aber sichtbares „Stand-up"-Flackern
  alle 30 s.
- **0.17–0.19:** Dummy-Anim-Refresh-Trick mit `SYNC`-Asset
  (Start+Sleep+Stop einer Mini-Anim, Hauptanim unangetastet).
  Multi-Avatar-Test in 0.19 bestätigte: refresht Skeleton-State, aber
  **nicht** die Loop-Phase. Architektonisch dafür ungeeignet.
- **0.20:** zurück zu Stop+Start der Hauptanim, aber mit verkürztem
  Sleep auf 50 ms.
- **0.21:** Wall-Clock-Alignment-Bug-Fix (`llGetTime` → `llGetUnixTime`,
  weil `llGetTime` per-Script und nicht regions-weit ist). Symptom war
  „erster Re-Sync verschlimmert es, zweiter behebt es".
- **0.22 (current):** Auto-Tick-Konstrukt komplett entfernt; sitA hat
  nur noch den 90271-Handler. hudproxy entscheidet, wann gefeuert wird.
  Notecard-Direktive `RESYNC OFF` ebenfalls entfernt — wenn der HUD
  das Feature off lassen will, sendet er einfach kein 90271.

### Warum HUD owns policy

- **Pro-User-Customization.** Jeder User kann auf seinem HUD die
  gewünschte Re-Sync-Frequenz oder Manual-Mode einstellen. Auto-Tick
  in sitA wäre furniture-weit, hätte alle Sitter zwangsbeglückt.
- **Furniture-Creator entlastet.** Keine Notecard-Direktiven, keine
  cfg-Felder, keine LSD-Migration.
- **sitA-Memory.** Die ~80 Zeilen Auto-Tick-Code (Wall-Clock-
  Scheduling, Multiplexing mit Sequence-Timer, RESYNC-Globals,
  state_entry-Read) waren in einem Skript, das ohnehin am 64-KB-
  Mono-Cap kratzt. Out + 90271-Handler = Netto-Memory-Gewinn.
- **Diagnose und Tuning** liegen im HUD-Repo, das eine Menü-UX hat —
  geeigneter Ort als ein notecard-getriebener Setup.
