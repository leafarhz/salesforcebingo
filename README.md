# Salesforce Networking Bingo

Conference networking bingo, running entirely on Salesforce with **no login for players**.
Scan a QR, enter your email, get a 5×5 card, and fill it by meeting people.

Built for Dreamforce 2026 — 5×5 grid, free centre square, 55 prompts.

## How it works

| | |
| --- | --- |
| **Access** | Experience Cloud LWR site, public guest access. No accounts, no passwords. |
| **Identity** | Your email is the key. Same email → same card, on any device, forever. |
| **The card** | Not stored. Derived from your email via a seeded shuffle of the prompt pool. |
| **Marking** | Pick the registered player you met from a typeahead. Both of you score. |
| **Scoring** | Derived from the marks log on every read. Nothing stored, nothing to reconcile. |

## The constraint that shaped everything

Experience Cloud **guest users can INSERT and READ, but never UPDATE**:

```
System.TypeException: DML operation UPDATE not allowed on Bingo_Mark__c
```

That is an object-CRUD check *below* the sharing layer, so `without sharing` does not
help, and guest profiles cannot be granted Edit — it is silently stripped. Guests also
cannot insert a record referencing a parent they lack access to, and cannot reliably
re-read a row they just wrote (sharing recalculation is asynchronous).

So nothing in this app updates anything:

- **Layouts are derived, not stored.** A seeded Fisher–Yates over the prompt pool
  (ordered by Id, seeded from the email) rebuilds the identical card every time. No
  card or square records exist, so there is nothing to create and nothing to
  cross-reference.
- **Marking and un-marking are both inserts** into `Bingo_Mark__c`, which has **no
  lookup fields**. Current state is the latest row per cell; a `Cleared__c` row turns
  a cell off, and re-marking turns it back on.
- **Scores are a pure function of that log.** No running totals to keep in sync.
- **No read-after-write.** A freshly written mark is merged in memory rather than
  re-queried.

The upshot is a complete audit trail of every connection made, as a side effect.

## Scoring

| Event | Points |
| --- | --- |
| Square marked | +1 (max 24) |
| Line completed — row, column or diagonal | +5 (12 possible) |
| Blackout | +25 bonus |
| Being named by someone else | +1, uncapped |

Helper points count only marks still in effect — un-marking takes the point back.
Values are constants in `BingoService`.

> At +2 per help, a well-known person wins without marking a single square. +1 keeps
> helping worthwhile without dominating.

## Components

| | |
| --- | --- |
| `bingoCard` | Container. Owns all state and every Apex call. Entry → grid → zoomed tile. |
| `bingoSquare` | One tile. Presentational: reports a tap, holds nothing. |
| `bingoTileDetail` | Zoomed view — full prompt at readable size, typeahead, mark / clear. |
| `bingoLeaderboard` | Standalone ranked standings. Optional auto-refresh for a booth screen. |

A 5×5 grid on a phone is unreadable, so the grid is a glance surface and tapping a tile
zooms into a view with room to read and type.

## Objects

| | |
| --- | --- |
| `Bingo_Player__c` | Email (unique External Id), display name, consent. Written once. |
| `Bingo_Prompt__c` | The prompt pool. Seed from `data/prompts.json`. |
| `Bingo_Mark__c` | Append-only log. No lookups, by design. |

## Deploy

```bash
sf org login web -a bingo                     # sandbox or Developer Edition
sf project deploy start -o bingo -d force-app
sf org assign permset -o bingo -n Bingo_App_Access
sf apex run test -o bingo -n BingoServiceTest
```

Then seed the prompts (see `data/prompts.json`), create a **Build Your Own (LWR)** site,
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
- **Freeze the prompt pool once play begins.** Layouts are derived from it, so adding or
  deactivating a prompt reshuffles every card.

## Tests

`BingoServiceTest` — 23 tests, including the full game loop executed as the real
Experience Cloud guest user via `System.runAs`.

See [PLAN.md](PLAN.md) for the full design history and the empirical findings behind it.
