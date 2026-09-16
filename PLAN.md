# Dreamforce 2026 Networking Bingo — Build Plan

**Decisions locked:** Experience Cloud LWR site + guest user + native LWC (Option A).
Marking a square requires entering **who you met**.

**Org:** any Salesforce sandbox or Developer Edition org with Digital Experiences enabled. Examples below use the CLI alias **`bingo`**.

---

## Where this stands

**Server: done, 18/18 green.** Schema, derived layouts, append-only marking, win
detection, 55 seeded prompts, guest access proven end to end.

**Front end: three LWCs deployed.**

| Component | Role |
| --- | --- |
| `bingoCard` | Container. Owns all state and every Apex call. Entry form → grid → zoomed tile. Exposed to `lightningCommunity__Page`. |
| `bingoSquare` | One tile. Purely presentational — reports a tap, holds nothing. Reusable for a read-only leaderboard board. |
| `bingoTileDetail` | Zoomed view: full prompt at readable size, "who did you meet?" input, mark / clear / back. |

Notable choices:
- **Optimistic marking.** The tap paints immediately, then reconciles with the
  server's card; on failure it rolls back. Waiting on a round-trip over Moscone
  wifi would make every tap feel broken.
- **Board replaced wholesale, never mutated.** LWC does not re-render on nested
  mutation, so an in-place `squares[i].isMarked = true` would update nothing.
- **Stable `key` per square**, or LWC reuses DOM across re-renders and marked
  state smears between cells.
- **Email cached in `localStorage`** so a returning player skips the form. Purely
  a convenience — the card is derived server-side from the email either way.
  Wrapped in try/catch because private mode throws.

### Manual steps left (Experience Builder — not scriptable)

1. Open Experience Builder for **Networking Bingo** → drag **Networking Bingo Card**
   onto the home page.
2. **Publish** the site, then **Activate** it (currently `UnderConstruction`).
3. Open in a private window: `https://<your-domain>.my.site.com/<site-path>`
   — this is the real test of the refresh case.
4. Point the QR at that URL.

---

## Why the design is insert-only (18/18 green)

The blocker below was real, but it's solved without leaving Option A. Guests **can**
insert; they just can't update. So nothing updates.

- **Layout is derived, not stored.** A seeded Fisher–Yates over the prompt pool
  (ordered by Id, seeded from the email) means the same email always rebuilds the
  identical card. No card or square records exist, so there is nothing to create at
  session start and nothing to cross-reference.
- **Marking and un-marking are both inserts** into `Bingo_Mark__c`, which has **no
  lookup fields**. Current state = latest row per cell; a `Cleared__c` row turns a
  cell off. Re-marking turns it back on.
- **No read-after-write.** Guest sharing recalculation is async, so a guest cannot
  reliably re-query a row it just inserted — the freshly written mark is merged in
  memory instead. (This was a real failure: the insert succeeded but `markedCount`
  came back 0.)
- Guest needs only **Create + Read**, the two permissions it is allowed to hold.

`guestCanPlayTheWholeLoop` runs register → derive → mark → un-mark as the real site
guest user and passes.

**Still to verify on the published site:** a guest reading marks from a *previous*
request (the refresh case) depends on guest sharing recalculation having completed.
Same-transaction is handled; cross-transaction needs a real browser check.

**Known cruft:** `Bingo_Card__c` and `Bingo_Square__c` are orphaned in the org —
unused and unreferenced, but the Metadata API refuses to delete them
(`INSUFFICIENT_ACCESS: EntityObject can not be initialized with null EntityInfo`).
Delete them from Setup by hand, or leave them.

---

## The constraint that forced this design

Everything below was verified empirically in the sandbox, not inferred from docs.

| # | Finding | Evidence |
| - | ------- | -------- |
| 1 | **Guest profiles can hold Create + Read, but `Edit` is silently stripped to `false`.** Deploying `allowEdit=true` "Succeeds" and the org still shows `edit: false`. | `ObjectPermissions` query after a successful deploy |
| 2 | **Guest sharing rules grant Read only.** `Edit` isn't in the enum. | `'Edit' is not a valid value for the enum 'ShareAccessLevelRead'` |
| 3 | **`without sharing` does not give guests record access.** | Same class, same query: admin saw 55 prompts, guest saw **0** |
| 4 | **A guest can't insert a child referencing a parent it created in the same transaction.** Sharing recalculation is async, so the new card isn't shared yet when the squares insert. | `INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY` |
| 5 | `ModifyAll`/`ViewAll` cannot be granted to a guest profile — silently stripped. | same as #1 |

**Consequence:** an Experience Cloud guest can never *update* a record. Tapping a square to mark it is an update, so the core game loop is impossible on Option A. Guest users suit **insert-only forms**; they do not suit a stateful board.

**Where Phase 0 fell short:** it tested "can a guest *write*" and passed — but write meant *insert*. It never exercised *update*, which is where the wall is. The spike was right to exist and right to run first; its scope was too narrow.

**Current suite: 14/15 green.** The only red is `guestUserCanStartASession`, which now correctly documents the blocker rather than hiding it.

### Options

- **B — External React app + one integration user** *(recommended)*: app on Vercel/Heroku, all Salesforce writes through a connected app (JWT/client-credentials). No guest limits at all, keeps React, best booth UX. This is what the original planning doc recommended for UX.
- **C — Guest + Platform Events**: guest *publishes* an event (allowed), a subscriber trigger runs as Automated Process in system context and does the writes. Keeps zero-login, but every tap becomes eventually consistent and it's a lot of machinery.
- **A′ — Authenticated Experience Cloud**: self-registration/login so users own their records and get real CRUD. Standard, but adds signup friction at a booth.

**None of the server-side work is wasted** — the schema, `BingoService`, win detection and the 55 seeded prompts are reusable under any of these; only the access path changes.

---

## Phase 0 — guest *writes* (insert) work

`BingoServiceTest` passes 5/5, including `guestUserCanCreateAPlayer`, which runs
`startSession` as the real site guest user via `System.runAs`.

**Two things the spike proved wrong or non-obvious — both cost real time:**

1. **`without sharing` does NOT bypass object-level permissions for guest users.**
   The original plan assumed guests needed no object access. False — every call
   failed with `Access to entity 'Bingo_Player__c' denied` until the **Guest User
   Profile** was granted explicit `objectPermissions` + `fieldPermissions` +
   `classAccesses`. `without sharing` only bypasses *record sharing*.

2. **Fields deployed via Metadata API get no FLS for anyone — including admins —
   and then behave as if they don't exist.** `Display_Name__c`, `Consented__c` and
   `Consented_At__c` deployed "Successfully", yet were absent from
   `FieldDefinition` and failed Apex compilation with *"Variable does not exist"*.
   `Email__c` worked only because it is `required`, and **required fields bypass
   FLS**. Fix: grant FLS via permission set (staff) and guest profile (players).
   Expect this for every new field — budget for it.

**Residual risk:** `System.runAs` may not perfectly reproduce a real anonymous
HTTP request — in particular the "guest users can't own records" rule and the
**guest record default owner** setting. The faithful test is hitting the
published site anonymously in a private window. Do that before Phase 3.

**Built so far:** `Bingo_Player__c` (+4 fields), `BingoService`, `BingoServiceTest`,
`Bingo_App_Access` permission set, `Networking Bingo Profile` guest grants, and the
**Networking Bingo** LWR site (path prefix `bingovforcesite`, status
UnderConstruction).

---

## 1. Player flow

1. Attendee scans a QR code → public Experience Cloud site URL. No login.
2. Enters **email** (the key) + display name + consent checkbox.
3. Server upserts a `Bingo_Player__c` on Email, assigns a card (1–20), returns the 5×5 grid.
4. Player taps a square → prompted **"Who did you meet?"** → name saved, square marked.
5. On 5 in a row (row / column / diagonal, free centre counts) → win screen: "Show this at the booth."
6. Blackout (all 24) = grand prize tier.

---

## 2. Why Option A, and what it costs

UIBundle React apps are **authenticated App-Launcher-only** experiences on `.salesforce.app`; there is no guest story (the multiframework-recipes repo has zero Experience Cloud / guest references, and GA doesn't support App Builder placement). Anonymous QR access rules them out.

Experience Cloud LWR + guest user is the standard, well-trodden path for public Salesforce-hosted apps. **Trade-off accepted: no React, so none of the Multi-Framework work carries over.**

---

## 3. Data model

All objects OWD **Private**. Record-level access comes only from `without sharing` Apex — but the guest profile still needs **object CRUD + FLS granted explicitly** on every Bingo object and non-required field (see Phase 0 findings).

| Object | Fields |
| --- | --- |
| `Bingo_Player__c` | `Email__c` (Text, **External Id**, Unique — enables upsert, no User record needed), `Display_Name__c`, `Consented__c` (Checkbox), `Consented_At__c` |
| `Bingo_Prompt__c` | `Text__c` (Text 255), `Active__c` (Checkbox) — seeded with the 55 extracted prompts |
| `Bingo_Card__c` | `Player__c` (Lookup), `Card_Number__c` (Number 1–20), `Bingo_Achieved__c` (Checkbox), `Bingo_At__c` (DateTime — **tie-break for prizes**), `Blackout__c` (Checkbox), `Blackout_At__c` |
| `Bingo_Square__c` | Master-Detail → `Bingo_Card__c`, `Prompt__c` (Lookup), `Row__c`, `Col__c` (Number), `Is_Marked__c`, `Marked_At__c`, **`Met_Person_Name__c`** (Text) |

Volume: 500 players × 25 squares = ~12.5k rows. Trivial.

`Met_Person_Name__c` is the point — it makes this real networking rather than tap-to-win, and gives a genuinely interesting post-event report ("who got mentioned most").

---

## 4. Apex surface — `BingoService` (`without sharing`)

```apex
@AuraEnabled startSession(String email, String displayName, Boolean consented)  // upsert player, get/assign card, return DTO
@AuraEnabled markSquare(Id squareId, String metPersonName)                       // mark + re-evaluate win, return updated state
@AuraEnabled unmarkSquare(Id squareId)
@AuraEnabled getLeaderboard()                                                    // first-to-bingo ordered by Bingo_At__c
```

Notes:
- `without sharing` bypasses **record sharing only**. Object CRUD and FLS are still enforced for guest users, so the Guest User Profile must grant them (Phase 0 proved this). Do **not** add `WITH USER_MODE` — that would additionally enforce sharing and break guest access.
- Return **DTOs**, never raw SObjects — keeps FLS surprises out of the wire format.
- Win check = 12 lines (5 rows, 5 cols, 2 diagonals); centre (2,2) always counts as marked.
- Card assignment: **deterministic** — `Math.abs(email.toLowerCase().hashCode()) % 20 + 1`. Same email always gets the same card, so a re-entry is idempotent and there's no "I lost my card" failure mode.

---

## 5. LWC components

| Component | Role |
| --- | --- |
| `bingoApp` | Container; holds session state, routes between entry / card / win |
| `bingoEntry` | Email + name + consent |
| `bingoGrid` | 5×5 layout, responsive (must work one-handed on a phone) |
| `bingoSquare` | Single cell; marked/unmarked visual state |
| `bingoMarkModal` | "Who did you meet?" prompt |
| `bingoWin` | Win state + claim instructions |
| `bingoLeaderboard` | Optional public board |

All must expose `lightningCommunity__Page` (+ `lightningCommunity__Default`) targets to be droppable in the LWR builder.

---

## 6. Experience Cloud / guest config — the risky part

1. Enable Digital Experiences, choose a domain.
2. Create an LWR site ("Build Your Own").
3. Set **guest record default owner** (Digital Experiences → Settings) — guest users **cannot own records**, so without this, inserts fail.
4. Grant the site's **Guest User Profile**: Apex class access to `BingoService`, **plus `objectPermissions` on every Bingo object and `fieldPermissions` on every non-required field**. Without these the guest gets `Access to entity ... denied` — this is not optional (Phase 0).
5. Leave "Secure guest user record access" **on** (default). We're not relying on guest record visibility at all.
6. Publish + activate the site; QR points at the site URL.

---

## 7. Seeding

`bingo/data/` already holds the extracted source of truth:
- `cards.json` — all 20 cards, 5×5, verified against the printed PDF (card 1 matched exactly)
- `prompts.json` — 55 unique prompts
- `extract_cards.py` — re-runnable if the PDF changes

Seed order: 55 `Bingo_Prompt__c` → then card templates. Player cards are materialised on first `startSession` call, not pre-created.

---

## 8. Phases

| Phase | Work | Why |
| --- | --- | --- |
| ~~0~~ | ~~Spike guest write~~ — **DONE, passed 5/5.** See findings at top. | Retired the main risk. |
| 1 | Remaining objects (`Bingo_Prompt__c`, `Bingo_Card__c`, `Bingo_Square__c`) + seed the 55 prompts / 20 cards | Remember FLS grants on every new field. |
| 2 | `BingoService` + Apex tests (win detection is the logic worth testing) | |
| 3 | LWC UI, mobile-first | |
| 4 | Site build, guest perms, publish | |
| 5 | QR code, leaderboard, prize rules | |
| 6 | Dry run on real phones + concurrency check | |

---

## 9. Risks / open questions

- **Guest write access is the #1 unknown.** Salesforce locked this down hard from Winter '21. Phase 0 exists solely to prove it works before we build on it.
- **Moscone wifi is unreliable.** A server round-trip per tap will feel broken. Mitigate with optimistic UI + retry, and keep payloads small.
- **Anyone can enter anyone's email** and see/modify their card. For a booth game this is probably acceptable; if not, add a 4-digit PIN set at first entry. **Decide before launch.**
- **PII**: emails collected from attendees. Consent checkbox at entry + a deletion plan after the raffle.
- **Abuse**: guest Apex endpoints are public. Consider a simple per-email rate limit if we care.
- **Org choice**: a Developer sandbox gets refreshed and has an unfriendly URL. A Developer Edition org may suit a short-lived public thing better. **Open.**
- **Prompt frequency is uneven** across the 20 printed cards (`Has spoken at a Salesforce community event` appears on 15 of 20; `Has taken a selfie with a Salesforce mascot` on 3). Affects prize balance if cards differ in difficulty.

---

## Scoring & leaderboard (added)

Registration is now **required** to claim a square: you pick the person from a
typeahead of registered players. Cold start is handled operationally — the
20-minute pre-session presentation is the registration window.

**Points are derived, never stored** — guests cannot update a running total, so
score is a pure function of the marks log. Nothing to recalculate, nothing to keep
in sync, and a refresh is always authoritative.

| Event | Points |
| --- | --- |
| Square marked | +1 (max 24) |
| Line completed (row / column / diagonal) | +5 (12 possible) |
| Blackout | +25 bonus |
| Being named by someone else | +1, uncapped |

Helper points count only **in-effect** marks — un-marking a square takes back the
point it gave. A naive `COUNT()` got this wrong: the original row still exists
underneath the `Cleared__c` row that supersedes it.

The leaderboard never derives anybody's card layout: a completed line depends only
on *which* cells are marked, not which prompt sits in them. Two queries total,
regardless of player count.

**Tuning note:** at +2 per help, a well-known person wins without marking a single
square — the leaderboard test demonstrated exactly that. +1 keeps helping
worthwhile without dominating. Values are Apex constants.

### Two risks to decide on

1. **Async guest sharing vs. late registrations.** A player who registered seconds
   ago may not yet be findable in the typeahead, because guest sharing
   recalculation is asynchronous. The 20-minute window covers the bulk; latecomers
   will have a short blind spot. If it bites, fall back to matching on typed name.
2. **Roster visibility.** The typeahead needs guest read on `Bingo_Player__c`, so a
   determined guest could reach names *and emails* via the UI API. Emails never
   appear in any DTO — `searchPlayers` returns an opaque record id — but the
   records themselves are reachable. Mitigation if it matters: split display names
   into a separate object that carries no email.
