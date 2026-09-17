# Salesforce Networking Bingo

Conference networking bingo, running entirely on Salesforce with **no login for players**.
Scan a QR, enter your email, get a 5×5 card, and fill it by meeting people.

Built for the LATAM Community Meetup at Dreamforce 2026.

---

> ## ⚠️ Scope: this is a party game, not a product
>
> This was built in a day for a **single 45-minute session with about 40 people**. It is
> deliberately not production-grade, not forward-designed, and not hardened. It is
> published because the guest-user findings below are genuinely useful to other people,
> not because the code is a reference implementation.
>
> **There is no authentication of any kind.** Your email is a lookup key, not a
> credential — anyone who types your email gets your card and can change it. That was a
> deliberate trade for zero friction at a booth, and it is completely unacceptable for
> anything that matters.
>
> Read [Known limitations](#known-limitations) before reusing any of this.

---

## How it works

| | |
| --- | --- |
| **Access** | Experience Cloud LWR site, public guest access. No accounts, no passwords. |
| **Identity** | Email as the key. Same email → same card, on any device. |
| **The card** | Not stored. Derived from the email via a seeded shuffle of the prompt pool. |
| **Marking** | Pick the registered player you met from a typeahead. Both of you score. |
| **Scoring** | Derived from the marks log on every read. Nothing stored, nothing to reconcile. |
| **Branding** | A `Bingo_Event__mdt` record, so the app is reusable for another event. |

## The constraint that shaped everything

Experience Cloud **guest users can INSERT and READ, but never UPDATE**:

```
System.TypeException: DML operation UPDATE not allowed on Bingo_Mark__c
```

That check sits *below* the sharing layer, so `without sharing` does not help, and guest
profiles cannot be granted Edit — it is silently stripped. Guests also cannot insert a
record referencing a parent they lack access to, and cannot reliably re-read a row they
just wrote, because sharing recalculation is asynchronous.

So nothing in this app updates anything:

- **Layouts are derived, not stored.** A seeded Fisher–Yates over the prompt pool
  (ordered by Id, seeded from the email) rebuilds the identical card every time.
- **Marking and un-marking are both inserts** into `Bingo_Mark__c`, which has **no lookup
  fields**. Current state is the latest row per cell; a `Cleared__c` row turns a cell off.
- **Scores are a pure function of that log.** No running totals to keep in sync.
- **No read-after-write.** A freshly written mark is merged in memory, not re-queried.

A useful side effect: a complete audit trail of every connection made.

## Rules

- **One person, one square.** Naming the same friend on all 24 squares would win without
  meeting anyone, so each person counts once per card. Clearing a square frees them again.
- **Free centre square**, pre-marked, counted in lines but not in progress.
- **Ties break on who got there first**, not alphabetically — prizes come off the top of
  the board, so the ordering has to be defensible out loud.

| Event | Points |
| --- | --- |
| Square marked | +1 (max 24) |
| Line completed — row, column or diagonal | +5 (12 possible) |
| Blackout | +25 bonus |
| Being named by someone else | +1, uncapped |

> At +2 per help, a well-known person wins without marking a single square. +1 keeps
> helping worthwhile without dominating. Values are constants in `BingoService`.

## Name matching

Typing a full name has to find someone registered under a short one. A single
`LIKE '%term%'` only tests containment in one direction, so "Rafael Hernandez" could not
find "Rafa". Matching therefore happens in Apex:

- Tokens are compared **in both directions** (`contains`, not just `startsWith`).
- **Accents are folded** — "Hernandez" finds "Hernández".
- Tokens are **OR'd**, so a longer query returns *more* results, not fewer. Requiring
  every token to match would break the case above. Precision comes from ranking: exact
  beats prefix beats contains, and a first-name hit outranks a surname hit.
- A **three-character minimum overlap** stops particles (*de*, *la*, *dos*) making every
  name match every other one, with an exemption for names that are genuinely that short.

## Components

| | |
| --- | --- |
| `bingoCard` | Container. Owns all state and every Apex call. Entry → grid → zoomed tile. |
| `bingoSquare` | One tile. Presentational: reports a tap, holds nothing. |
| `bingoTileDetail` | Zoomed view — full prompt, typeahead, mark / clear. |
| `bingoLeaderboard` | Standalone standings. Optional auto-refresh for a booth screen. |

A 5×5 grid on a phone is unreadable, so the grid is a glance surface and tapping a tile
zooms into a view with room to read and type.

## Objects

| | |
| --- | --- |
| `Bingo_Player__c` | Email (unique External Id), display name, consent. Written once. |
| `Bingo_Prompt__c` | The prompt pool. Seed from `data/prompts.json`. |
| `Bingo_Mark__c` | Append-only log. No lookups, by design. |
| `Bingo_Event__mdt` | Per-event branding and copy. |

## Deploy

```bash
sf org login web -a bingo                     # sandbox or Developer Edition
sf project deploy start -o bingo -d force-app
sf org assign permset -o bingo -n Bingo_App_Access
sf apex run test -o bingo -n BingoServiceTest
```

Then seed the prompts (`data/prompts.json`), create a **Build Your Own (LWR)** site,
enable public access in Experience Builder, drop `Networking Bingo Card` on a page, and
publish.

### Gotchas that cost real time

- **New fields deploy with no field-level security for anyone** — including admins — and
  then behave as if they do not exist (`Variable does not exist`, missing from
  `FieldDefinition`). Required fields are the exception, because they bypass FLS. Grant
  FLS on every non-required field, in both the permission set and the guest profile.
- **Guest profiles need explicit object CRUD and FLS**, plus a **guest sharing rule**
  (`sharingGuestRules`, Read only — `Edit` is not a valid access level).
- **Every LWC change needs a site republish** before players see it.
- **Freeze the prompt pool once play begins.** Layouts derive from it, so adding or
  deactivating a prompt reshuffles every card mid-session.
- `on` and `like` are **reserved words in Apex**. Both cost a deploy.

## Tests

`BingoServiceTest` — **38 tests, 97% coverage of `BingoService`**, including the full game
loop executed as the real Experience Cloud guest user via `System.runAs`.

There are **no LWC (Jest) tests** and no CI. The UI was verified by hand on a phone.

---

## Known limitations

Ordered roughly by how much they would matter if you reused this.

**Security and privacy**

- **No authentication.** Email is a lookup key, not a credential. Anyone can enter anyone
  else's email and read or modify their card. A PIN at first entry would fix it; it was
  not worth the friction for a 45-minute game.
- **The roster is readable.** The typeahead needs guest read on `Bingo_Player__c`, so
  display names *and email addresses* are reachable by a determined guest through the UI
  API. DTOs never return emails, but the records are exposed. Splitting display names into
  an email-free object would fix it.
- **No rate limiting or abuse protection** on any public endpoint.
- **Data deletion is manual.** Nothing expires or purges on a schedule.

**Correctness and trust**

- **Entirely honour-based.** Nothing verifies two people actually met.
- **The prompt pool must be frozen during play.** Layouts derive from it; changing it
  reshuffles every card mid-session.

**Scale**

Sized for tens of players, not thousands:

- `getLeaderboard` reads **every** mark and scores in memory.
- `searchPlayers` loads up to 2000 players and matches in Apex. At real scale this should
  be SOSL.
- The marks log is append-only and never compacted.

**Operational**

- Tied to whichever org it is deployed in; a QR pointing at a sandbox dies if the sandbox
  is refreshed.
- Experience Builder steps (public access, pages, publish) are manual and not scripted.
- Accessibility has not been audited. There are ARIA labels and 44px tap targets, but no
  screen-reader testing.
- The script typeface on the masthead falls back through `Snell Roundhand` and
  `Brush Script MT` to generic cursive — faithful on Apple platforms, plainer elsewhere.
- `Bingo_Card__c` and `Bingo_Square__c` may remain in the org as orphans from an earlier
  design. They are unused, and the Metadata API refuses to delete them
  (`INSUFFICIENT_ACCESS: EntityObject can not be initialized with null EntityInfo`).
  Delete from Setup by hand.

See [PLAN.md](PLAN.md) for the full design history and the empirical findings behind it.
