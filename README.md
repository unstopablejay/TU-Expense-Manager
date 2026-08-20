# TU Expense Tracker

An Android app that turns bank SMS alerts into a categorized expense ledger, and supports manually adding transactions (such as cash/manual entries). It parses incoming spend and credit alerts, stores them in a local SQLite database, and learns a merchant → category mapping so that categorizing a merchant once applies to every past *and* future transaction from that merchant.

Everything stays on the device by default. There is no backend and no network call unless you choose to run one — see [Self-hosting](#self-hosting-optional), which is entirely optional and off until you configure it.


## How it works

```
incoming SMS ─► SmsParser ─► merchant_mappings lookup ─► transactions row
                                    │                          │
                          hit → that category                  ▼
                          miss → 'Uncategorized'      transactions
                                                               │
                                                    tap a row ─┤
                                                               ▼
                             ┌──────────────┬──────┬───────┬────────┐
                       change category    note   split       delete
                       (this row; the    (why    across
                        merchant default  this   several
                        is opt-in)        one)   categories
```

A merchant that always sells the same thing gets a default category and is filed
automatically. One like Amazon, whose charges cover groceries and shopping at once, is set
to **always ask** and split by hand into lines that sum to the charge — so the categories
on the Dashboard still add up to what was actually spent.

### The SMS templates

`SmsParser.templates` in `lib/main.dart` is an ordered list of `SmsTemplate`s, tried
top to bottom, first match wins. Each one is a single end-to-end anchored regex with
named groups (`amount`, `instrument`, `merchant`, `date`, optional `ref`).

Nothing in the parser recognises a bank. The account or card text is *captured* into
`payment_type` and never matched on, so one template serves every issuer that sends that
wording. `BANK`, `MERCHANT`, `PAYEE` and `PAYER` below stand in for whatever the message
actually carries.

**Confirmed** — matched against real message bodies:

| Wording it keys on | Shape | Direction |
|---|---|---|
| merchant after an `@` | `INR 204.00 spent on BANK Card X2858 @MERCHANT 13-08-2026 09:21:35 am` | debit |
| opens with "Spent", merchant after " At " | `Spent Rs.122.02 On BANK Card 6824 At MERCHANT On 2026-08-13:07:19:26` | debit |
| "Sent … From … To …", one field per line | `Sent Rs.18.00` / `From BANK A/C *0444` / `To PAYEE` / `On 10/08/26` / `Ref 213313774670` | debit |
| "spent using", merchant after the date | `INR 160.00 spent using BANK Card XX8008 on 11-Aug-26 on MERCHANT.` | debit |

**Unconfirmed** — written from wording that is common across issuers, *not* from a real
message. Replace them with the genuine body when one turns up:

| Wording it keys on | Shape | Direction |
|---|---|---|
| "debited by … trf to" | `A/C X1234 debited by 150.0 on date 11Aug26 trf to PAYEE Refno 123456789` | debit |
| "debited from … at" | `INR 500.00 debited from A/c no. XX1234 on 11-08-26 12:30:45 at MERCHANT.` | debit |
| "spent on … at", date mid-sentence | `Rs.500.00 spent on BANK Card X1234 on 11-Aug-26 at MERCHANT.` | debit |
| "credited to … from" | `Rs.500.00 credited to BANK A/c XX0444 from PAYER on 11/08/26 Ref 123456789` | credit |
| "Received … in … from" | `Received Rs.500.00 in BANK A/c XX0444 from PAYER on 11/08/26 Ref 123456789` | credit |
| "is credited with … by" | `Your A/c XX1234 is credited with Rs.500 on 11-08-26 by PAYER` | credit |

Notes on the design:

- **Direction comes from the matched template, never from a keyword scan.** This is
  load-bearing: `Spent Rs.39791.72 From BANK Card x2227 At PZCREDIT9772829` is a
  *debit* whose merchant name happens to contain `CREDIT`. Searching the body for
  "credit" would book Rs.39,791.72 as income. There is a test for exactly this.
- Anchoring every pattern end to end removes the old "which rupee figure is the
  amount" problem structurally. `Avl Lmt`, `Avl Limit:` and `Bal` figures sit outside
  the capture groups and can no longer be picked up, so nothing depends on
  `firstMatch` ordering any more.
- A template that matches but yields nonsense (unparseable amount, empty merchant,
  out-of-range date) falls through to the next template instead of rejecting the
  whole message, which is what the old all-or-nothing `parse()` did.
- The account-to-payee transfer alert is multi-line. Dart's `.` does not cross a newline
  but `\s` does, so the captures are `[^\n]*?` joined by `\s+` — the same pattern also
  matches the flattened single-line form you get from pasting.
- One `_parseDate` covers every shape seen: `dd-MM-yyyy hh:mm:ss am/pm`,
  `yyyy-MM-dd:HH:mm:ss`, `dd/MM/yy`, `dd-MM-yy HH:mm:ss`, `dd-MMM-yy` and `ddMMMyy`.
  Two-digit years pivot to `2000 + yy`. Ranges are checked explicitly because
  `DateTime` silently rolls month 13 over into the next January.
- Timestamps are converted by hand rather than with `DateFormat`, so lowercase `am`
  and uppercase `AM` both parse with no locale data initialization. 12 am maps to
  `00:00` and 12 pm to `12:00`.
- UPI alerts carry a date but **no clock time**. For those, `parse()` adopts the time
  of day from the SMS arrival timestamp when the SMS arrived on that same date, and
  otherwise falls back to midnight. Keeping the message's own date means a late inbox
  scan can't drag a transaction onto the scan day, and a re-scan reproduces the exact
  same timestamp — so ingestion stays idempotent.
- `parse()` returns `null` when no template matches, which is how OTPs, promos
  and statement alerts are filtered out.

### Database

Schema version 7. Seven tables, created on first launch (`AppDatabase`):

```sql
categories           (id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
merchant_mappings    (merchant_name TEXT PK COLLATE NOCASE, category_id INTEGER FK)
name_aliases         (kind TEXT, alias TEXT COLLATE NOCASE, canonical TEXT,
                      PRIMARY KEY (kind, alias))
transactions         (id INTEGER PK, amount REAL, payment_type TEXT,
                      merchant TEXT COLLATE NOCASE, date INTEGER, category_id INTEGER FK,
                      direction TEXT DEFAULT 'debit', reference TEXT DEFAULT '',
                      note TEXT NOT NULL DEFAULT '')
transaction_splits   (id INTEGER PK, transaction_id INTEGER FK ON DELETE CASCADE,
                      category_id INTEGER FK, amount REAL, position INTEGER DEFAULT 0)
deleted_transactions (amount REAL, merchant TEXT COLLATE NOCASE, date INTEGER,
                      direction TEXT, reference TEXT DEFAULT '',
                      payment_type TEXT, category_id INTEGER,
                      original_id INTEGER, deleted_at INTEGER, splits_json TEXT,
                      note TEXT,
                      PRIMARY KEY (amount, merchant, date, direction, reference))
app_meta             (key TEXT PK, value TEXT)
```

- `date` is stored as epoch milliseconds.
- `direction` is `'debit'` or `'credit'`, from the matched template.
- `reference` is the UPI Ref / UTR / Refno when the message carries one, else `''`.
- `note` is free text the user typed against the transaction — the *why* behind a charge,
  which no bank alert carries. It is `NOT NULL DEFAULT ''`; `''` means there is no note,
  and saving an empty field is how one is removed, so there is no delete path and no null
  to handle. `cleanNote` trims it, collapses inner whitespace onto single spaces and caps
  it at 140 characters on the way in, so the stored value is always the one-line string
  the tile renders.
- `COLLATE NOCASE` on the merchant columns means `Swiggy` and `SWIGGY` resolve to one
  mapping, while the original casing is still what gets displayed.
- A `UNIQUE (amount, merchant, date, direction, reference)` index makes ingestion
  idempotent — re-scanning the inbox or receiving a duplicate broadcast can't create a
  second row. `direction` is in the key because a debit and a matching refund can share
  a timestamp; `reference` is in it because UPI alerts have no clock time, so two
  genuine same-day payments of the same amount to the same payee are otherwise
  indistinguishable.
- `name_aliases` records which labels have been merged: `kind` is `'merchant'` or
  `'payment_type'`, `alias` is a label the bank sent, `canonical` is what to call it. It is
  applied **when rows are read**, never by rewriting them, which is what lets a future alert
  in the old format fold in by itself and what makes a merge undoable. Keys are stored
  lower-cased and the column is `COLLATE NOCASE`, so one row covers `HDFC Bank A/C *0444`
  and `HDFC Bank A/c *0444` at once. Resolution is always a single hop — merging into a name
  that is itself a merge result re-points the older rows rather than chaining onto them.
- `deleted_transactions` holds the natural key of every transaction deleted on purpose,
  and its first five columns mirror that index exactly, `COLLATE NOCASE` included, so
  the two keys compare identically. The index above only stops the *same* SMS being
  imported twice — the message itself is still in the inbox, so without a tombstone any
  later rescan would faithfully bring a deleted row back. `insertParsed` checks it
  before writing. Those five columns alone are the primary key; `payment_type`,
  `category_id`, `original_id`, `deleted_at` and `note` are payload, carried so the Deleted
  section can display a deleted transaction and restore it exactly — same card, same
  category, same note, same row id — without the original still being in memory. `note` is
  nullable there for the usual reason, and NULL is right: a tombstone written before v7 has
  no note to carry.
- `transaction_splits` holds the category/amount lines of a transaction that covers more
  than one category — a single ₹2,000 Amazon order that was really ₹1,200 of groceries,
  ₹500 of snacks and ₹300 of shopping. **A transaction with no rows here is unsplit**, and
  its `category_id` speaks for the whole amount; that is why the migration needs no
  backfill, since an empty table already says exactly that about every existing row.

  **For a split transaction, `transactions.category_id` is a denormalised cache of the
  largest line**, refreshed by `saveSplits` in the same SQL transaction. It keeps the
  `JOIN categories` in `transactions()`, the headline chip and a tombstone restore working,
  and it is never read for money math once lines exist. Everything that totals anything
  reads `ExpenseTxn.effectiveSplits` instead — the real lines, or a synthesised single line
  for an unsplit row — so no code has to ask whether a transaction is split.

  `transaction_id` cascades, so deleting a transaction drops its lines. `category_id`
  deliberately does not: it mirrors `transactions.category_id`, so deleting a category
  still in use is refused rather than quietly removing money lines and leaving a split that
  no longer sums to its transaction. There is no `UNIQUE (transaction_id, category_id)` —
  two lines in one category are legal and simply add up.

  The sum invariant spans rows, so SQLite cannot express it as a `CHECK`. `saveSplits`
  enforces it within half a paisa, and the editor puts the rounding remainder on the last
  line so what is stored sums exactly.
- `app_meta` is key/value scratch space, currently just `last_scanned_sms_date` — the
  `date` of the newest inbox message already processed. Its absence is what makes the
  next scan a full one.
- Seed categories: Uncategorized, Grocery, Food, Fuel, Shopping, Bills & Utilities,
  Travel, Entertainment, Health. New ones can be added from the picker.

#### Migration v1 → v2

`onUpgrade` adds `direction` and `reference`, then drops and recreates the natural-key
index over the wider tuple. Every v1 row predates any notion of spend-vs-receive, so it
is a debit with no reference — exactly what the two column defaults supply, which is
why no backfill statement is needed.

#### Migration v2 → v3

Creates `deleted_transactions` and `app_meta`. Both start empty and no backfill is
needed: nothing has been deleted yet, and an absent watermark is exactly the state that
triggers a full first scan — so an upgraded install reads its whole inbox once, then
goes incremental like a fresh one.

#### Migration v3 → v4

Adds `payment_type`, `category_id`, `original_id` and `deleted_at` to
`deleted_transactions`. All four are nullable because SQLite cannot
`ADD COLUMN ... NOT NULL` without a default, and a v3 tombstone genuinely has no value
for them — v3 recorded only enough to keep a row deleted, not enough to bring it back.
Such a tombstone still lists in the Deleted section and still restores; it just comes
back as `Unknown` / Uncategorized under a fresh id. The branch is keyed on
`oldVersion == 3` rather than `< 4`, since a database arriving from v2 or earlier gets
the full v4 table from `CREATE TABLE` and must not then be altered.

#### Migration v4 → v5

Creates `transaction_splits` and its index, and adds `splits_json` to
`deleted_transactions`.

No backfill: an empty splits table already asserts that every existing transaction is
unsplit, which is true. `splits_json` must be nullable — SQLite cannot
`ADD COLUMN ... NOT NULL` without a default — and NULL is the right value anyway, since a
tombstone written before v5 has no lines to carry. It decodes to no splits.

The `ALTER` is guarded on `oldVersion >= 3`, the same shape of reasoning as the v3 branch
and dependent on running after it: a database arriving from v2 or earlier had
`deleted_transactions` created from the shared const moments earlier, which already carries
`splits_json`. Only one created by the v3 or v4 text is missing the column.

#### Migration v5 → v6

Creates `name_aliases`. No backfill and no column patching: an empty table says nothing has
been merged, which is true of every database that predates the feature.

#### Migration v6 → v7

Adds `transactions.note` and `deleted_transactions.note`. No backfill: the `''` the default
supplies is not a placeholder for missing data, it is the truth — a transaction imported
before notes existed genuinely has none. The tombstone `ALTER` is guarded the same way the
v5 `splits_json` one is, and for the same reason: a database arriving from v2 or earlier had
`deleted_transactions` created from the shared const, which already carries `note`.

### Notes

Any transaction can carry one short note, whatever its category — added from the same
actions sheet that categorises, splits and deletes a row. On the list it sits immediately
to the right of the category pill, italic and behind a small icon, on the line the pill
already occupies: a note costs the row no extra height, and a row without one is unchanged.
Long notes ellipsise there and are shown in full in the sheet.

A note belongs to the transaction, not to a split line — a split still carries one note for
the charge as a whole. It survives categorising, splitting and merging a merchant, and it is
carried in the tombstone so delete-and-undo does not lose the one part of a row nobody could
reconstruct. The Deleted section shows it, which is often the only thing separating two
identical-looking charges when choosing which to restore.

### Categorization

On insert, the merchant is looked up in `merchant_mappings`. A hit uses that category;
a miss falls back to `Uncategorized`.

**Categorising one transaction changes that transaction and nothing else.** Making the
pick the merchant's rule as well is a separate, opt-in checkbox in the picker. The narrow
behaviour is the default because the wide one is far more than anyone means by correcting
a row — and because a merchant-wide sweep would otherwise flatten a split entered by hand.

`merchant_mappings` therefore holds a row only where a default was set deliberately, which
is what lets **Settings › Merchants & defaults** show three distinct states:

| State | Stored as | Means |
|---|---|---|
| Not set | no mapping row | never configured |
| Always ask me | mapping to `Uncategorized` | looked at, and left uncategorised on purpose |
| A category | mapping to that category | new transactions land there |

"Always ask me" is for a merchant like Amazon whose charges always cover several
categories and always need splitting by hand. It needs no schema of its own: `insertParsed`
reads the mapping to `Uncategorized` and applies it, which is exactly the desired outcome.

Setting a real default asks before touching history — "also apply to N past transactions?"
— and both the count and the update share one predicate, `_backfillableWhere`, so the N
confirmed is the N changed:

```sql
merchant = ? AND category_id <> ?
AND id NOT IN (SELECT transaction_id FROM transaction_splits)
```

`category_id <> ?` keeps the number honest; excluding split rows is what stops a
merchant-wide default overwriting a per-transaction breakdown. A default of `Uncategorized`
is **never** backfilled even if asked, since applying "always ask me" backwards would erase
the very work it exists to protect.

### Splitting

One SMS is one amount, so an Amazon order covering groceries, snacks and shopping arrives
as a single ₹2,000 charge. Tagging it with all three categories would count ₹2,000 three
times over and the totals would stop adding up; splitting it into lines that sum to the
charge keeps every total exact.

Tapping a transaction opens its actions sheet — **Change category**, **Split**, **Delete** —
on either tab. The split screen is rows of category and amount, and **the last row always
carries the balance**: type 1,200 against a ₹2,000 charge and the second row becomes 800 on
its own; add a third and type 300 in the second, and the third becomes 500. Editing the last
row directly is allowed and can leave the split unbalanced, which shows as
"₹500 unallocated" or "₹200 over" and blocks Save until it is resolved.

Under a category filter a split contributes **only its matching lines** — the ₹2,000 Amazon
row shows and totals ₹1,200 under Grocery. That is what keeps a filtered view's totals
equal to what was really spent.

## App icon

The artwork lives at `assets/icon/app_icon.png` and is the source of truth — it is not
bundled into the APK (it is not declared under `flutter: assets:`), it is only what the
launcher icons are cut from.

`android/app/src/main/res/` carries two forms of it:

- **`mipmap-anydpi-v26/ic_launcher.xml`** — the adaptive icon used from API 26 up. Its
  background is the flat `@color/ic_launcher_background` (`#EEEBE8`, sampled from the
  artwork so the two layers meet with no seam) and its foreground is the badge cut out
  of that backdrop, drawn at the 72dp safe zone of the 108dp canvas.
- **`mipmap-*/ic_launcher.png`** — the flattened fallback for API 24–25, which predates
  adaptive icons.

The badge is deliberately kept inside the 72dp safe zone. That is the spec, and it also
measured right: this emulator's circular mask shows only about 73% of the 108dp canvas,
so the badge fills 91% of the visible circle while its dark rim — the icon's only edge
against a light wallpaper — keeps a hair of margin. Scaling past the safe zone clipped
that rim away entirely.

## Releasing

`.github/workflows/release.yml` builds the signed APK. It runs on two triggers, and
they do different things:

- **Pushing a `v*` tag** builds the APK and publishes it as a GitHub Release named after
  the tag. This is the one that produces a keepable, shareable build.
- **A manual run** (Actions → Release APK → Run workflow) builds the same APK but
  attaches it to the run as a build artifact, which expires and needs repo access to
  download. Useful for a throwaway check without minting a version.

Pushing code on its own builds nothing.

```bash
git tag v1.1.0 && git push origin v1.1.0
```

**The tag name is the version.** The workflow derives `versionName` from it, so `v1.2.0`
produces an APK that reports 1.2.0, and `versionCode` comes from the run number, which
only ever increases. There is nothing to keep in sync by hand — `pubspec.yaml`'s version
applies only to local builds and manual runs.

That was not always true. `v1.0.0`, `v1.0.1` and `v1.0.3` each shipped an APK still
reporting `1.0.0` build `1`, because the build read `pubspec.yaml` and nothing ever
updated it, so no device could tell those releases apart.

A tag is frozen to one commit. **A new release always needs a new tag** — re-releasing an
existing tag rebuilds that same old commit, and in fact does not even start the workflow,
since no new ref is pushed. Re-pushing the *same* tag is safe though: the publish step
uses `--clobber`, so a re-run repairs a release rather than duplicating it.

## Requirements

Android only. `sqflite` and the SMS plugin have no desktop or web implementation, and
the project has just an `android/` target.

## Setup

```bash
flutter pub get
flutter run
```

Two pieces of Android configuration are load-bearing — the app builds but silently
receives nothing without them:

- **`android/app/src/main/AndroidManifest.xml`** declares
  `com.shounakmulay.telephony.sms.IncomingSmsReceiver` alongside the `RECEIVE_SMS` and
  `READ_SMS` permissions. The plugin requires the *app* to register that receiver;
  without it `listenIncomingSms` never fires.
- **`android/build.gradle.kts`** nudges plugin modules still pinned to Kotlin
  `jvmTarget = "1.8"` up to 11, to match the Java target AGP 9 compiles them with.
  It must stay above `evaluationDependsOn(":app")`, which eagerly evaluates `:app` —
  `afterEvaluate` throws on an already-evaluated project.

This uses `another_telephony` rather than `telephony`. The original 0.2.0 declares no
Gradle namespace and uses `lintOptions` / `compileSdkVersion 31`, none of which survive
AGP 8+. The fork is API-identical; only the import differs.

## Usage

Three destinations on a bottom navigation bar: **Dashboard**, **Transactions** and
**Settings**. The app opens on the Dashboard.

**Both screens are scoped to a month, and open on the current one.** The ledger used to be
unbounded, which made its headline total mean "everything since I installed the app" — a
number nobody acts on. A period row sits at the top of each, naming the months on show,
with `‹` `›` steppers to move one month at a time and a sheet to tick several. The two
screens keep **separate** month selections: comparing three months on the Dashboard should
not dump three months of rows into the working list, and scrubbing back through the list
should not silently repoint the charts.

### Dashboard

Where the money went over the chosen period. It reads the whole ledger and narrows it by
month **and nothing else** — deliberately not inheriting the Transactions tab's category,
merchant, card or search filters, because a report steered by a working list's filter
state is not a report, and a pie of a single category is not a chart.

- A **hero figure**: total spent, with received and net beneath it.
- **One month → a donut**, capped at the five largest categories plus an "Other" holding
  the tail, with a ranked list of exact amounts and shares beside it. The cap and the list
  are both deliberate: a donut is honest about part-to-whole at a glance and useless for
  comparing two close values, so the figures have to be readable somewhere — and that list
  is also what keeps the chart usable for anyone who cannot separate two of the hues.
- **Two or more months → grouped bars**, one group per category and one bar per month,
  coloured by month with a legend naming them. Two pies cannot be compared by eye; bars
  can. Capped at six months, past which the bars are thinner than the gaps between them.

**Category colours are assigned from the category's name, never from its rank.** Were
slots handed out by position in the sorted-by-spend list, Food would be blue in a month it
led and orange in one it did not, and the eye would read a colour change as a change in
the data. Credits are excluded from every chart — a refund is not spending. "Other" and
Uncategorized are grey on purpose: neither is something money was spent *on*, and giving
them a hue would let the tail of the breakdown compete with the real answers.

### Transactions

Everything that happened, spend and received together, filtered, sorted and edited in
place. Under the period row and the search box is a scrolling row of chips, each opening a
sheet.

This section describes the phone. The browser shows the same ledger, with the same
filters and the same orders, as a sortable table with the filters as dropdowns — see
[One ledger, two layouts](#one-ledger-two-layouts). Everything below about *what* a
filter or an order means holds in both; only the controls differ.

#### Sorting

The first chip names the current order rather than saying "Sort", since an order is always
in force:

- **Newest first** (default) — what the query already returns, so it costs nothing.
- **Oldest first** — the exact reverse, ties included.
- **Amount: high to low** / **low to high**
- **Merchant A–Z** — case-insensitive.

Sorting happens in Dart over the filtered rows, not in SQL, and the amount orders compare
**what the row shows**. Under a category filter a split contributes only its matching
lines, so a ₹2,000 Amazon order narrowed to Grocery sorts on its ₹400 grocery line, not on
₹2,000 — otherwise the list would order itself by figures the user has filtered out and
cannot see. Every order falls back to date then id, so ties come out stable.

#### Searching

A search box above the chips matches **notes and merchant names**, case-insensitively, on
any part of a word. Those two fields because they are the only free text a transaction has:
one the user wrote, one the bank sent.

It ANDs with the chips rather than replacing them, and it narrows which *transactions*
survive, never which lines do — a search term says nothing about categories, so a split it
matches still shows its whole breakdown while a category chip may still narrow it.

**The query deliberately takes no part in computing the facet options.** Were it one of
them, typing a letter would retire options and the pruning step would then discard a
category or merchant already picked — a keystroke silently clearing a filter, and clearing
the search box would not bring it back.

Matching runs in Dart over the loaded rows, with no debounce: the ledger is already in
memory and is filtered on every build regardless, so a keystroke costs one pass over a local
list.

#### Filtering

Three facets, as chips that open a sheet:

- **Category** — take as many as you like. Only categories something actually falls under,
  so a choice can never filter to nothing. The category *picker* still offers the full
  list; it has to, since assigning is how a category first gets used.
- **Merchant** — likewise multi-select, one entry per distinct merchant.
- **Card / account** — one entry per distinct `payment_type`, e.g. `YES BANK Card
  X2858`, `HDFC Bank A/C *0444`.

All three lists are derived from the loaded transactions rather than queried, so they stay
in step for free. **Category and merchant constrain each other**: pick Amazon and the
category chip offers only Amazon's categories; pick Grocery and the merchant chip offers
only merchants with grocery spend.

Each facet computes its options with every filter applied *except its own*. That is the
whole trick, and skipping it reintroduces an old bug: narrowing to one card must not empty
the category list underneath a selection already made in it, and by the same token picking
one merchant must not leave the merchant list holding only that merchant.

Selections that stop being available are dropped rather than filtered on. The facets are
ANDed and the summary totals reflect them; a split contributes only the lines that matched,
so a Grocery-filtered view of a ₹2,000 Amazon order shows ₹1,200 and totals ₹1,200. When
the filters exclude everything, a **Clear filters** button appears (distinct from the empty
state shown when there are no transactions at all).

#### Editing

The list is the working surface — there is nowhere else to go to change something:

- **Tap any transaction** to open its actions sheet — amount, card, date, categories and
  any note, over **Change category**, **Add / Edit note**, **Split** and **Delete**.
  Uncategorized rows are flagged in the error color. A split row's pill names its first
  category and counts the rest ("Grocery +2"); the sheet lists them all with their amounts.
- **Add a note** to record why a charge happened. It appears on the row just right of the
  category pill, and is matched by the search box. Clearing the field and saving removes
  it — there is no separate delete.
- **Swipe a row left to delete it**, with an **Undo** action on the snackbar. Delete is
  permanent by design: a tombstone is recorded so the transaction is not re-imported by
  a later scan, and Undo lifts that tombstone and restores the row under its original
  id. Credits are listed here too, so a mis-parsed one can be removed.

  Swipe is withheld from a row that is showing **less than it would remove**. Under a
  category filter a split displays only its matching portion, but deleting takes the whole
  transaction, and swipe is the one delete with no confirmation behind it. Those rows are
  still deletable through the actions sheet, which prints the full amount at the top.
- **Long-press to mark**, then tap to mark more. The app bar becomes a selection bar
  with a count, select-all, and delete; the whole marked set goes in one SQL
  transaction, so a bulk delete is all or nothing, and Undo brings back exactly those
  rows. While marking, tap-to-categorize and swipe-to-delete are both suspended so a
  stray gesture can't act outside the flow, and Back leaves selection before it leaves
  the app.

  **Select all means all of what the filters left on screen**, not the whole ledger —
  filter to one merchant and the count matches what you can see. The chip row hides while
  marking, so the filters cannot move under a selection already made; that is what keeps
  "all of them" unambiguous, and it makes filter-then-bulk-delete the natural way to clear
  out a run of rows.

  Bulk delete confirms first. That dialog is not ceremony: the selection bar's delete
  icon occupies exactly the screen position the overflow menu does otherwise, so a reach
  for the menu can land on it, and unlike a swipe nothing about tapping an app bar icon
  reads as destructive. A single swipe-delete still goes straight through, since the
  gesture is deliberate and the Undo snackbar catches it.
- **Paste an SMS** (FAB) feeds a message straight into the parser, prefilled with a
  sample, so the pipeline can be exercised without SMS permission.
- **Merge merchant** and **Merge card / account** open the merge screen with that row's
  name already ticked. They act on the name rather than on the transaction — the row is
  simply where a duplicate is usually noticed.

### Merging duplicates

One real card, account or merchant arrives under several labels, because each template
captures the issuer text verbatim and the banks are not consistent. A single account can
show up as `BANK A/c XX0444`, `HDFC Bank A/C *0444` and `HDFC Bank A/c XX0444` — three
entries in the filter, with the totals split across them.

**Merge merchants** and **Merge cards & accounts** under Settings → Cleanup fix that, and
each screen has three parts:

- **Merged** — what is currently folded together, and the labels each name covers, with a
  **Separate** action. Nothing was overwritten, so separating simply drops the rule.
- **Looks like duplicates** — groups the app spotted, shown ticked but never merged without
  a press. Cards group on their trailing digits; merchants group on a squashed form
  (lower-cased, punctuation stripped, a leading `UPI_` dropped) so `UPI_GEORGE EGG CENTRE`
  and `GEORGE EGG CENTRE` come up together. Both heuristics can be wrong — two genuinely
  different cards can end in the same four digits — which is why they only ever suggest.
- **All** — every current name, tick two or more and Merge.

Merging asks what to call the result, offering the most-used spelling. That sheet is the
confirmation; the snackbar behind it carries **Undo**.

**Merging a merge works and does not resurrect anything.** Fold A and B into "Rapido", then
fold "Rapido" and C into "Rapido Rides", and A and B are re-pointed at the new name rather
than left hanging off the old one. Only "Rapido Rides" is offered afterwards.

Two consequences worth knowing:

- **A default set on a merged merchant is written for every label it covers.** Ingest looks
  the default up under the raw merchant the SMS parsed to — it has to, since the alias is
  resolved on the way out, not the way in — so a mapping keyed only on the merged name would
  never be found. Backfill likewise spans all of them.
- **`RAPIDO` and `Rapido` never need merging.** The database has always treated them as one
  merchant (`COLLATE NOCASE` on the column, the mappings key and the natural-key index), and
  the ledger now folds case-only variants onto the most common spelling on read. Only the UI
  ever showed them as two.

The Deleted section still shows the label a transaction was actually filed under, not the
merged name: a tombstone is a record of what was removed, and its merchant is part of the
key that finds the row again.

### Settings

The second destination on the navigation bar: **Merchants & defaults**, the **Cleanup**
merge screens, **Server sync** (address, device name, sign in, sync now, sync
automatically and how often), the update controls (automatic check, check now,
install), and version information. Leaving it reloads the ledger, because a default changed there can be
backfilled over history — without the reload the rows behind it would keep showing the
categories they had on the way in.

### Deleted transactions

**Deleted transactions** in the overflow menu opens every tombstone, newest first, each
with a **Restore** action. Restoring lifts the tombstone *and* re-inserts the row, which
is why it needs no separate "make importable again" action — those are the same thing.
Rows written before schema v4 restore as `Unknown` / Uncategorized under a fresh id,
because that is genuinely all v3 recorded.

**Long-press to mark** works here too, for bulk restore: the app bar becomes the same
selection bar with a count, select-all and restore, and the whole marked set goes back
in one SQL transaction. The per-row Restore button is hidden while marking, so there is
only ever one way to act. Marks are keyed by natural key rather than row id, since a
tombstone has no id of its own, and a reload drops marks for anything restored
elsewhere in the meantime.

The header shows **Total spent** always, and adds **Received** plus **Net** once any
credit has been recorded. The category breakdown counts debits only — a refund is not
spending. Credit rows carry a `+` and a green amount in the list.

### Scanning

- **First launch** reads the entire inbox automatically once the SMS permission is
  granted — no button press needed.
- **Every launch after that** looks only at messages newer than the last one processed,
  using a real `WHERE` on the SMS content provider rather than re-reading everything.
- The watermark advances to the newest message *actually seen*, not to the clock, so a
  skewed device time cannot strand real messages behind it. It only moves forwards, and
  only after a scan that completed — a scan that failed or was denied leaves it alone so
  the next attempt covers the same ground.
- **Check for new SMS** (toolbar) runs that same incremental pass on demand.
- **Rescan all messages** (overflow menu) ignores the watermark and re-reads the whole
  inbox. Safe to run at any time — duplicates are caught by the natural-key index and
  deleted rows by their tombstones. Worth doing after the parser learns a new template.

Alerts arriving while the app is open are still picked up live by the foreground
listener. It does not touch the watermark; a message it already inserted may be re-read
by the next scan, where the natural key drops it.

### Export, backup and restore

**Settings → Data** holds both halves of one idea. **Export data** writes the whole
database to an `.xlsx` workbook and hands it to the Android share sheet, which is how it
reaches Drive — and from Drive, Google Sheets, which opens `.xlsx` natively with filters
and pivots intact. **Restore from backup** reads one of those workbooks back over the
top of everything.

It is deliberately *one* file rather than a pretty spreadsheet plus an opaque `.db`
alongside it. A backup you can open, read and sanity-check is worth more than one you
have to trust, and keeping the two in one file means there is no way to end up holding
the wrong half of a pair.

Seven sheets: **Transactions**, **Splits**, **Categories**, **Merchant defaults**,
**Name aliases**, **Deleted** and **Meta**. The readable columns are on the left of each
sheet and the machinery on the right, so opening the file lands you on dates, amounts and
merchant names rather than on ids.

Two things about the Transactions sheet are load-bearing:

- It carries **both** `Merchant` and `Merchant (as stored)` (and the same pair for the
  card). The first is resolved through any merge, which is what you want to filter on;
  the second is the string the column actually holds, and it is the one a restore reads.
  It has to be, because the merchant is part of the natural key — export the merged
  spelling and the backup's tombstones would no longer match its transactions, which
  shows up only as deleted rows quietly returning after the next rescan.
- It carries both a `Date` cell and a `Timestamp (ms)` cell. The date is there so Sheets
  sorts and filters it as a date; the millis are what a restore reads, because an Excel
  serial date has no timezone and this value sits inside a unique index.

Columns are matched **by header name, not by position**, so sorting, hiding, or adding a
column of your own in Sheets does not stop the file restoring. Display-only columns are
recomputed on the next export, so typing over the merged `Merchant` column changes
nothing.

Restore **replaces everything**, in one SQL transaction. Before anything is deleted, the
file is decoded, validated in full, and confirmed by a dialog naming both counts; then a
copy of the current data is written as `tu-expense-before-restore-<date>-<time>.xlsx`
beside it. So every way a restore can fail is a way that leaves the ledger alone, and the
one way it can succeed is still reversible. Validation refuses a backup from a *newer*
schema outright rather than importing it hopefully — a newer version may have columns
this build has never heard of, and dropping them silently would make a backup lossy at
exactly the moment it is being relied on.

Ids are preserved exactly, including the `AUTOINCREMENT` counters, because
`deleted_transactions.original_id` points at `transactions.id` and a tombstone restores
its row under that id. Renumbering on import would break undo for every deleted row in
the backup.

Not included: the update-checker's `SharedPreferences` settings, which are preferences
rather than data.

## Testing

```bash
flutter analyze
flutter test
```

`test/widget_test.dart` covers the parser: the four verified templates against their
real message bodies, thousands separators, the 12 am/12 pm boundaries, every unverified
template, the arrival-time fallback for date-only messages, and rejection of OTPs,
statement alerts and promos. Two cases specifically guard against regressions that
looked plausible: `PZCREDIT9772829` staying a debit, and the trailing `Bal` /
`Avl Limit:` figures never being mistaken for the amount.

It also covers the ledger, chart, merge and split logic — `applyFilters`, `amountIn`,
`spendByCategory`, `categoryOptions`, `merchantOptions`, `monthOptions`, `pruneSelection`,
`sortEntries`, the period model (`YearMonth`, `periodLabel`, `comparedMonths`), the chart
aggregation (`spendByCategoryPerMonth`, `periodTotals`, `topCategories`), the empty-list
reasoning (`emptyReason`), notes (`cleanNote`), the merge rules (`NameAliases`,
`mergePlan`, `canonicaliseLedger`, `suggestGroups`), the split arithmetic (`unallocated`,
`isBalanced`, `withRemainderInLast`) and the tombstone payload (`encodeSplits`,
`decodeSplits`). All are pure top-level functions precisely so
they can be tested without a database behind them; anything worth covering is written that
way.

Cases specifically guarding regressions this design invites: a split found by the category
of its *smallest* line (proving the filter reads lines rather than the cached
`category_id`), a category offered by the facet only because it appears as a minor split
line, a facet ignoring its own selection so it cannot empty itself, an amount sort reading
the filtered portion of a split rather than the whole charge, oldest-first breaking its ties
oldest-first so it is a true reverse of newest-first, a chained merge re-pointing its
earlier members so they cannot resurface, a case-only merge keeping the spelling that was
chosen rather than dropping the row as redundant, ten paise divided three ways staying
balanced, and the last line absorbing that drift so what is stored sums exactly.

The backup workbook is covered the same way, `encodeBackupWorkbook` /
`decodeBackupWorkbook` / `validateBackup` being pure functions over raw row maps for
exactly that reason. A full round trip is asserted row by row over a fixture holding one
of everything awkward — a split, a credit, a null card, empty notes and references, a
merged merchant, a tombstone carrying splits and a pre-v4 tombstone that is null
throughout. The two that would otherwise fail silently have their own cases: an amount of
`1234.5678901234567` surviving as the identical `double` and still matching its
tombstone's natural key, and a whole-rupee `204.0` coming back as a double rather than the
int the excel package's reader turns `"204.0"` into. Around those sit the robustness
claims — columns reordered, a column the user added, a display column typed over, trailing
blank rows — and one refusal case per validation rule.

The database and widget layers have no automated coverage: `AppDatabase` needs the real
sqflite plugin, and `sqflite_common_ffi` is deliberately not a dependency. Delete, restore,
splits, the migrations, the scan watermark and the two backup methods (`exportAll`,
`replaceAll`) are verified by hand, below.

To exercise the live path end to end on an emulator:

```bash
# one per confirmed template; the issuer text is captured verbatim, never matched on
adb emu sms send BANKSMS "INR 204.00 spent on BANK Card X2858 @UPI_GEORGE EGG CENTRE 13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08"
adb emu sms send BANKSMS "Spent Rs.122.02 On BANK Card 6824 At INNOVATIVE RETAIL CONC On 2026-08-13:07:19:26."
adb emu sms send BANKSMS "INR 160.00 spent using BANK Card XX8008 on 11-Aug-26 on AMAZON PAY IN G. Avl Limit: INR 3,99,614.00."
```

The transaction should appear on the Transactions tab within a second or two — provided it
is dated in the month on show; if it is not, the toast names the month it landed in.
Newlines don't
survive `adb emu sms send`, so for the one-field-per-line transfer alerts use
the **Paste an SMS** button instead. To inspect what was actually stored:

```bash
adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/e.db
sqlite3 /tmp/e.db "SELECT t.amount, t.merchant, t.direction, t.reference, c.name FROM transactions t JOIN categories c ON c.id = t.category_id;"
sqlite3 /tmp/e.db "PRAGMA user_version; SELECT * FROM app_meta; SELECT * FROM deleted_transactions;"
sqlite3 /tmp/e.db "SELECT s.transaction_id, c.name, s.amount FROM transaction_splits s JOIN categories c ON c.id = s.category_id ORDER BY s.transaction_id, s.position;"
sqlite3 /tmp/e.db "SELECT merchant_name, category_id FROM merchant_mappings;"
sqlite3 /tmp/e.db "SELECT kind, alias, canonical FROM name_aliases;"
```

Worth walking by hand, since none of it is covered by `flutter test`:

- **Upgrade, not reinstall.** Install the previous build, scan a few alerts, then
  install this one over the top: the rows must survive and `user_version` must read 7.
- **Delete after a merge.** The one place merged names could do real damage. Merge a card
  or merchant, delete one of its transactions, and check the row actually went and the
  tombstone holds the **raw** label rather than the merged one — `_naturalKeyOf` uses
  `rawMerchant` precisely so the key still finds the row. Then Undo it.
  Worth doing from a v3-created database too, since the `splits_json` `ALTER` is guarded
  on `oldVersion >= 3` and a v2-or-earlier database must *not* take that branch.
- **Split adds up.** Split a ₹2,000 charge: the balance must flow into the last row as the
  ones above it are filled, Save must stay disabled while it is unbalanced or a row has no
  category, and the stored lines must sum to the charge exactly
  (`SELECT SUM(amount) FROM transaction_splits WHERE transaction_id = ?`).
- **Split survives delete.** Delete a split transaction, confirm `splits_json` on its
  tombstone holds the lines, restore it, and confirm all of them come back. Then rescan-all
  and confirm nothing duplicates.
- **An empty month shows an empty month.** Step back to a month with nothing in it. It must
  say "Nothing in <month> yet" and offer **Show all months** — *not* fall back to showing
  the whole ledger. This is the trap the whole month design is built around: an empty month
  set means "every month", so pruning a selection that matches nothing would invert the
  feature. Worth checking on the 1st of a month specifically, which is when the *default*
  selection is the empty one.
- **A category keeps its colour.** Note Food's colour on the Dashboard in a month it leads,
  then switch to a month where it does not. It must be unchanged — colours are assigned by
  name, and assigning by rank would make a colour change look like a data change.
- **An import you cannot see says so.** With the list on this month, paste an alert dated
  last month. The row correctly does not appear, and the toast must name the month it went
  to. Same for **Rescan all messages**, which imports mostly out-of-month rows.
- **A note outlives every edit.** Note a transaction, then categorise it, split it, and
  merge its merchant: the note must still be there each time — the merge is the one that
  matters, since `canonicaliseLedger` rebuilds every row through `copyWith`. Then delete it
  and Undo, and confirm the note came back with it.
- **A note never crowds the row out.** Type a note at the 140-character cap: the tile must
  ellipsise it on the one line it shares with the category pill, the amount must stay put,
  and the sheet must show the whole thing.
- **Search does not clear a filter.** Pick a category chip, then type in the search box: the
  chip must survive every keystroke and clearing the box must leave it still applied.
- **A default never eats a split.** Split one transaction from a merchant, then set that
  merchant's default and accept the backfill. The split row must be untouched, and the N in
  the prompt must have excluded it.
- **Always ask never backfills.** Set a merchant with categorised history to "Always ask
  me". No backfill prompt appears and the existing rows keep their categories — the older
  build would have re-tagged the lot to Uncategorized.
- **One row at a time.** Change a transaction's category with the checkbox unticked and
  confirm no other transaction from that merchant moved.
- **Delete sticks.** Delete a transaction whose SMS is still in the inbox, then run
  **Rescan all messages** — the strongest test, since it ignores the watermark. It must
  not come back, and must be counted as skipped.
- **Undo.** Swipe, tap Undo, confirm the row returns with its category intact and that a
  later rescan doesn't duplicate it — the tombstone has to be gone.
- **Bulk delete.** Long-press, mark three, delete, confirm: three tombstones sharing one
  `deleted_at`, all three rows gone, and Undo restoring exactly those three. Cancelling
  the dialog must change nothing *and* leave the marks in place.
- **Restore round trip.** Delete a row, open **Deleted transactions**, restore it, and
  confirm it comes back with its `payment_type`, `category_id` and `original_id` intact
  — that payload is the entire point of the v4 columns. Then rescan-all and confirm the
  restored row is not duplicated.
- **Bulk restore.** Long-press in the Deleted section, mark several, restore: all come
  back under their original ids, the unmarked ones stay deleted, and the selection
  clears.
- **Incremental scanning.** Relaunch with no new SMS: nothing imported, watermark
  unchanged. Then `adb emu sms send` one alert and relaunch: only that one is processed
  and `last_scanned_sms_date` advances.
- **Export/restore round trip.** The one worth doing whenever any of it is touched, since
  `exportAll` and `replaceAll` are the two methods `flutter test` cannot reach. With a
  ledger that has at least one split, one merge, one merchant default and one deleted row
  in it, dump the tables, export, damage the database, then restore and dump again — the
  two dumps must be identical, ids included:

  ```bash
  dump() { sqlite3 "$1" "SELECT 'T',* FROM transactions ORDER BY id;
    SELECT 'S',* FROM transaction_splits ORDER BY id;
    SELECT 'D',* FROM deleted_transactions ORDER BY merchant;
    SELECT 'A',* FROM name_aliases ORDER BY kind,alias;
    SELECT 'M',* FROM merchant_mappings ORDER BY merchant_name;
    SELECT 'K',* FROM app_meta ORDER BY key;"; }
  adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/before.db
  # …export from Settings → Data, damage the ledger, restore from the workbook…
  adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/after.db
  diff <(dump /tmp/before.db) <(dump /tmp/after.db) && echo identical
  sqlite3 /tmp/after.db "PRAGMA user_version; PRAGMA foreign_key_check;
    SELECT * FROM sqlite_sequence;"
  ```

  `user_version` must read 7, `foreign_key_check` must say nothing, and `sqlite_sequence`
  must match the source — a counter left high would keep issuing ids from wherever the
  replaced database had got to.
- **A rescan after a restore duplicates nothing.** The natural-key index and the
  tombstones both have to have come back for this to hold, so it is the real test that
  the merchant was exported as *stored* rather than as merged.
- **A bad workbook changes nothing.** Open an export in Sheets, break a `Category id`,
  and restore it: the dialog must name the offending transaction and the ledger must be
  untouched. Worth also trying a workbook whose `schema_version` you have edited upwards,
  which must be refused outright.
- **Wipe and recover.** Uninstall, reinstall, restore. The whole ledger comes back.

The database filename is still `expense_manager.db` — it predates the rename and is left
alone deliberately, since `getDatabasesPath()` resolves it under whatever the current
`applicationId` is. The `applicationId` itself moved from `com.example.expense_manager` to
`com.tu.expense.manager`, so a device carrying the old build will show both apps side by
side; uninstall the old one to drop its ledger.

## Self-hosting (optional)

Everything above works with no server at all, and nothing in this section changes
that: with no server address configured, the app makes no network call and behaves
exactly as it always has. This is an addition for anyone who wants their ledger on
their own hardware — the same shape as Immich or Jellyfin.

**One tap on the phone puts the whole ledger on a box you own, and the same screens
then open in any browser on your network.**

```
        PHONE (owns the ledger)                 YOUR SERVER (Docker)
  ┌──────────────────────────────┐        ┌────────────────────────────────┐
  │ SMS ─► parser ─► SQLite      │        │  one container, one port       │
  │                              │        │                                │
  │ Settings › Server sync       │        │  /api/v1/snapshot  POST │ GET  │
  │   Sync now ──────────────────┼───────►│  /api/v1/edits     GET  │ POST │
  │                              │        │  /*  the Flutter web build    │
  └──────────────────────────────┘        │                                │
                                          │  /data/users/<you>/devices/    │
  ┌──────────────────────────────┐        │      <device>/snapshots/       │
  │ PC BROWSER — same screens    │◄──────►│                                │
  └──────────────────────────────┘        └────────────────────────────────┘
```

### One ledger, two layouts

The browser renders the *same* `DashboardTab` the phone does, and derives what to show
with the same `deriveLedgerView`. There is one implementation of the charts, the
filters, the sort orders and the category colours. What differs is only what a browser
cannot own: it has no SQLite and no SMS, so the ledger arrives as a snapshot rather
than from a query.

The transactions list is the deliberate exception, and it used to be shared too. A
column of cards is right on a phone and wasteful on a desktop: one short line of text
per transaction stretched across a 1920px window, with the filters behind a
horizontally scrolling strip of chips that each opened a bottom sheet — a touch idiom
being pointed at with a mouse. So above 900px the browser draws the ledger as
`WebTransactionsView`: a sortable table with the filters as real dropdown menus across
the top. Below 900px — a phone browser, a narrow window — it falls back to the phone's
own `TransactionsTab`, unchanged.

**What is shared there is the logic, not the pixels.** The table is handed rows
`deriveLedgerView` has already filtered and ordered, totals them with the same
`periodTotals` and `spendByCategory`, blames the same `emptyReason` for an empty list,
and colours categories with the same `categoryColor`. Nothing in it decides what the
ledger says; it only decides how it is drawn. That is the line that keeps the two
targets from disagreeing about a total — a second implementation of the *arithmetic* is
what would, and there isn't one.

That is possible because `lib/` is split along a platform boundary:

| | |
|---|---|
| `lib/src/core/` | Pure Dart. Models, the parser, ledger maths, the backup and snapshot codecs. No Flutter, no plugins. |
| `lib/src/ui_shared/` | Widgets both targets render. Flutter, `fl_chart` and `intl` only. |
| `lib/src/mobile/` | `AppDatabase`, the SMS source, the updater, and every screen that writes. |
| `lib/src/web/` | The browser's session, API client and shell. |

`test/purity_test.dart` enforces it. The first two directories may import nothing
outside themselves plus a fixed allowlist of packages with web implementations, and
every file in both is checked — so no import path of any length can reach sqflite or
`dart:io`. It runs in seconds on every test run, and it fails at the import rather
than at deploy time.

### Each device keeps its own ledger

Snapshots are stored per account **and per device**:

```
/data/users/jay/devices/<device-id>/snapshots/<timestamp>.json
```

This is not incidental. With a single slot, the last device to sync would overwrite
every other device's ledger — so pointing a phone and an emulator at one server
would destroy real data on the first sync. Each device also gets its own edit queue,
because an edit naming transaction 47 means a different transaction on a different
device.

The last 30 snapshots per device are kept. That history *is* the backup: every push
is a whole ledger, so recovering from a bad one means reading an older snapshot
rather than merging anything.

### Running it

Build and start it:

```bash
docker compose up -d
```

Set `EXPENSE_ADMIN_PASSWORD` to something long first. It creates the first account
on the first start and is ignored ever after, so leaving it in the compose file is
harmless and a typo in it cannot reset a password. More accounts later:

```bash
docker exec -it tu-expense-server /app/server --add-user sam
docker exec -it tu-expense-server /app/server --list-users
docker exec -it tu-expense-server /app/server --set-password jay
```

On **ZimaOS or CasaOS**, install through *Apps → + → Custom Install → Import* and
paste `docker-compose.yml`. The `x-casaos` block gives it a title, an icon and a
working WebUI link rather than an anonymous container.

The image itself is published by pushing a version tag:

```bash
git tag v1.2.0 && git push origin v1.2.0
```

That builds the signed APK and attaches it to a GitHub Release, and separately
builds the `linux/amd64` image and pushes it to
`ghcr.io/unstopablejay/tu-expense-server:1.2.0` and `:latest`.

**One thing to do once, after the first tag.** A new GHCR package is private even
when the repository is public, so ZimaOS pulling it gets `denied` — which reads
like a wrong image name rather than a permissions problem. Make it public at
*github.com/unstopablejay?tab=packages → tu-expense-server → Package settings →
Change visibility*, or keep it private and run
`docker login ghcr.io` on the box with a token that has `read:packages`.

Then, on the phone: **Settings → Server sync**, enter the address
(`http://192.168.1.99:8099`), sign in, and tap **Sync now**. In a browser, open the
same address and sign in with the same account.

### Environment

| Variable | Default | |
|---|---|---|
| `EXPENSE_ADMIN_USER` | — | Creates the first account, if there are none. |
| `EXPENSE_ADMIN_PASSWORD` | — | Its password. The server refuses to start with no accounts and no way to make one. |
| `PORT` | `8099` | |
| `DATA_DIR` | `/data` | |
| `SNAPSHOT_KEEP` | `30` | Snapshots kept per device. |
| `MAX_UPLOAD_BYTES` | `33554432` | 32 MB. |
| `EDIT_EXPIRY_DAYS` | `30` | Drops an edit no phone came to collect. |

### About the security of this

Written down plainly, because self-hosting means these are your decisions:

- **Plain HTTP.** Intended for a home LAN, or a WireGuard tunnel into it from
  outside. Nothing needs forwarding on your router, and nothing should be.
- **The password crosses the wire only at login**, and is exchanged for a session
  token used thereafter. A token can be revoked; a password cannot. Still, on plain
  HTTP that one request is readable by anything on the network, so use a password
  unique to this app.
- **Passwords are stored salted and hashed with Argon2id** (64 MiB, 3 iterations),
  never in a reversible form. That is why signing in takes a second or two, on
  purpose: it is what makes a stolen `users.json` expensive to attack.
- **A wrong username and a wrong password are refused identically**, in the same
  amount of time, so the server cannot be used to discover which accounts exist.
- **The session token lives in `localStorage`** in the browser, readable by any
  script on that origin. Acceptable for a private host serving only this app; **Sign
  out** clears it.
- **Every write is a temp file and a rename**, and the pointer to the current
  snapshot is only written once the snapshot exists — so a container killed
  mid-write leaves the previous snapshot current, never a half-written one.

TLS is a reverse-proxy configuration away if you want it; ZimaOS already runs Caddy.

### Editing from the browser

The browser can edit, and does it by **queueing intent rather than writing**.
Clicking a row of the table opens a dialog offering four things — change the
category, edit the note, split across categories, delete — and each one posts an
edit that the phone applies on its next sync. (A delete is also on each row
directly, appearing on hover: a mouse cannot swipe, which is how the phone offers
it.) The dialog is a dialog rather than a bottom sheet for the same reason the list
is a table — a sheet rising from the bottom edge of a desktop window is a phone
answering a question nobody asked it:

```
PC clicks "Grocery"  ──POST /api/v1/edits──▶  queued, seq 4
                                                  │
Phone syncs (on its own)  ◀───────────────────────┘  pulls the queue
   │  applies via setTransactionCategory(), the same method its own screens call
   └──▶ pushes a fresh snapshot, then acknowledges what it did
```

That order is deliberate. Applying before pushing means the snapshot the server
ends up holding already contains the edit, so a browser refresh shows it.
Acknowledging *after* the push means a crash in between re-applies an edit rather
than losing it — safe, because each one is idempotent by its `edit_id`.

Because the phone applies edits through its own methods, every rule it already
enforces still holds: split lines must sum to the transaction, a delete writes a
tombstone so a later inbox scan cannot resurrect the row, and the denormalised
category cache is refreshed in the same SQL transaction. No new write paths, no
schema change, no conflict resolution.

An edit names its transaction by **both** row id and natural key, and needs both
to agree. Ids are per-device and change under a restore; the natural key alone
cannot tell two identical charges apart. So an edit made against a row the phone
has since deleted resolves to nothing and is reported as skipped — never applied
to whatever now holds that id.

#### The phone syncs on its own

The queue is only half an editor if nothing drains it, so the app syncs without
being asked: when it opens, when you come back to it, every 15 minutes while it
is open (5, 30 or 60 on request), and about 20 seconds after you change something
on the phone. **Settings › Sync automatically**, on by default and inert until a
server is configured and signed into.

It is **foreground only** — nothing runs while the app is closed. Android will
not run a Flutter isolate on a timer without a background worker, and one of
those brings a plugin, a service notification on some builds, and a
battery-optimisation setting per manufacturer that silently switches it off. So
an edit made on a PC lands the next time the app is open, and **Sync now** is
still there for when that is not soon enough.

An automatic sync uploads only if the ledger actually changed. It fingerprints
the snapshot it would send — SHA-256 over the same encoding, minus the export
timestamp, so only real changes count — and skips the upload when that matches
what it last pushed *and* the server still holds that snapshot. Without it,
polling every quarter of an hour would fill the 30-snapshot history with 30
identical copies inside a day, and that history is the backup. Pressing **Sync
now** uploads regardless, because someone who pressed a button is owed a
snapshot.

#### The connection light

Top right of every app bar, on the phone and in the browser, and it is the same
widget in both: a dot, green when this device and the server are in touch, red
when they are not, grey when there is nothing to say — no server configured, or
no phone has ever synced. Hover or long-press it for the reason; tap it to check
again now. Solid for green and a ring for red, because roughly one man in twelve
cannot tell those two hues apart and a light whose whole meaning is a hue is a
light he cannot read.

The two ends know different things, so they ask different questions:

| | green means | red means |
|---|---|---|
| **Phone** | `/api/health` answered, or a sync just succeeded | the server did not answer — wrong address, server down, VPN not connected |
| **Browser** | that phone has reported within twice its own sync interval | that phone has gone quiet for longer than that, or this browser cannot reach the server either |

"Twice its own interval" is why the phone sends `X-Expense-Sync-Interval` on login
and on every sync. Without it the browser would have to guess at a schedule, and
be wrong for anybody who moved the setting: forty minutes of silence is a fault
at fifteen-minute syncing and unremarkable at hourly. Doubling it means missing
one sync — a lift, a VPN reconnecting — does not turn the light red, because a
light that cries wolf is one nobody looks at.

**Pulling the edit queue is the heartbeat.** `last_seen` used to move only when a
snapshot was pushed, and an automatic sync deliberately does not push an
unchanged ledger — so a phone syncing perfectly every quarter of an hour, on a
day with no new transactions, went quiet as far as the server could tell and the
browser called it disconnected. Every sync starts by pulling the queue, so that
is the request the server treats as checking in. It only ever touches a device it
already knows: a heartbeat must not be a way to create devices, or a typo in a
header would fill the device picker with entries that have no ledger behind them.

#### One character, and every edit vanished

Worth recording, because it survived a clean `flutter analyze`, a passing test
suite and a working build. The natural key spells the amount with
`double.toString()`, and that is round-trip exact on both targets but **not
identical between them**: on the VM `500.0` prints as `500.0`, while on the web a
double is a JavaScript number and the same value prints as `500`. The key is
composed in a browser and matched on a phone.

So every browser edit to a whole-rupee transaction addressed a row the phone
could not find, and came back as "skipped, no longer matched" — while an amount
ending in paise worked, which made it look intermittent rather than broken.
`canonicalAmountKey` now pins the VM's spelling on both, the comparison
canonicalises both sides so edits queued by older browser builds still apply, and
`test/natural_key_test.dart` asserts the characters — which only means anything
because CI runs the suite in Chrome as well as on the VM.

Two things the browser deliberately cannot do. It cannot create a category, since
that is not one of the four operations and a category no phone agreed to make
could not be applied. And it has no multi-select: that exists to drive a bulk
delete, which here would be one queued edit per row with no way to undo the set as
a set.

## Limitations

- **Foreground only.** The listener runs with `listenInBackground: false`, so alerts
  that arrive while the app is closed are not seen until the next launch — which now
  catches up automatically, so the gap is invisible unless you never open the app.
  Background delivery needs a top-level `@pragma('vm:entry-point')` handler with its own
  database connection.
- **Sync runs only while the app is open.** Automatic sync is a foreground timer, so
  an edit made in a browser waits until the app is next opened. Making it work with
  the app closed needs a background worker (`workmanager` or the like), which brings a
  per-manufacturer battery setting that can silently disable it.
- **Six of the ten templates are unconfirmed.** Everything under the "Unconfirmed"
  table was written from wording common across issuers rather than from a real message,
  so the exact phrasing may be wrong. A template that doesn't match simply means the
  message is ignored rather than mis-parsed, so the failure mode is a missing
  transaction, not a wrong one.
- **No credit alert has been seen yet.** All three credit templates are guesses. Paste
  a real one through **Paste an SMS** to check it lands under "Received".
- **Unmatched messages are silent.** There is no diagnostics view listing bodies that
  look like money but matched no template, so a wrong guess above is invisible until
  you notice a transaction missing.
- Flutter warns that `another_telephony` applies the Kotlin Gradle Plugin, which future
  Flutter versions will reject. It builds today, but that dependency is on a clock.
