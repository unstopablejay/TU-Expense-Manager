# TU Expense Tracker

An Android app that turns bank SMS alerts into a categorized expense ledger. It parses
incoming spend and credit alerts, stores them in a local SQLite database, and learns a
merchant → category mapping so that categorizing a merchant once applies to every past
*and* future transaction from that merchant.

Everything stays on the device. There is no backend and no network call.

## How it works

```
incoming SMS ─► SmsParser ─► merchant_mappings lookup ─► transactions row
                                    │                          │
                          hit → that category                  ▼
                          miss → 'Uncategorized'          dashboard
                                                               │
                                                    tap a row ─┤
                                                               ▼
                                     ┌───────────────┬──────────────────┐
                              change category      split          delete
                              (this row; the       across
                               merchant default    several
                               is opt-in)          categories
```

A merchant that always sells the same thing gets a default category and is filed
automatically. One like Amazon, whose charges cover groceries and shopping at once, is set
to **always ask** and split by hand into lines that sum to the charge — so the categories
on the dashboard still add up to what was actually spent.

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

Schema version 5. Six tables, created on first launch (`AppDatabase`):

```sql
categories           (id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
merchant_mappings    (merchant_name TEXT PK COLLATE NOCASE, category_id INTEGER FK)
transactions         (id INTEGER PK, amount REAL, payment_type TEXT,
                      merchant TEXT COLLATE NOCASE, date INTEGER, category_id INTEGER FK,
                      direction TEXT DEFAULT 'debit', reference TEXT DEFAULT '')
transaction_splits   (id INTEGER PK, transaction_id INTEGER FK ON DELETE CASCADE,
                      category_id INTEGER FK, amount REAL, position INTEGER DEFAULT 0)
deleted_transactions (amount REAL, merchant TEXT COLLATE NOCASE, date INTEGER,
                      direction TEXT, reference TEXT DEFAULT '',
                      payment_type TEXT, category_id INTEGER,
                      original_id INTEGER, deleted_at INTEGER, splits_json TEXT,
                      PRIMARY KEY (amount, merchant, date, direction, reference))
app_meta             (key TEXT PK, value TEXT)
```

- `date` is stored as epoch milliseconds.
- `direction` is `'debit'` or `'credit'`, from the matched template.
- `reference` is the UPI Ref / UTR / Refno when the message carries one, else `''`.
- `COLLATE NOCASE` on the merchant columns means `Swiggy` and `SWIGGY` resolve to one
  mapping, while the original casing is still what gets displayed.
- A `UNIQUE (amount, merchant, date, direction, reference)` index makes ingestion
  idempotent — re-scanning the inbox or receiving a duplicate broadcast can't create a
  second row. `direction` is in the key because a debit and a matching refund can share
  a timestamp; `reference` is in it because UPI alerts have no clock time, so two
  genuine same-day payments of the same amount to the same payee are otherwise
  indistinguishable.
- `deleted_transactions` holds the natural key of every transaction deleted on purpose,
  and its first five columns mirror that index exactly, `COLLATE NOCASE` included, so
  the two keys compare identically. The index above only stops the *same* SMS being
  imported twice — the message itself is still in the inbox, so without a tombstone any
  later rescan would faithfully bring a deleted row back. `insertParsed` checks it
  before writing. Those five columns alone are the primary key; `payment_type`,
  `category_id`, `original_id` and `deleted_at` are payload, carried so the Deleted
  section can display a deleted transaction and restore it exactly — same card, same
  category, same row id — without the original still being in memory.
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
times over and the dashboard would stop adding up; splitting it into lines that sum to the
charge keeps every total exact.

Tapping a transaction opens its actions sheet — **Change category**, **Split**, **Delete** —
on either tab. The split screen is rows of category and amount, and **the last row always
carries the balance**: type 1,200 against a ₹2,000 charge and the second row becomes 800 on
its own; add a third and type 300 in the second, and the third becomes 500. Editing the last
row directly is allowed and can leave the split unbalanced, which shows as
"₹500 unallocated" or "₹200 over" and blocks Save until it is resolved.

Under a category filter a split contributes **only its matching lines** — the ₹2,000 Amazon
row shows and totals ₹1,200 under Grocery. That is what keeps a filtered dashboard's totals
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

One screen over the ledger, with **Settings** alongside it on a bottom navigation bar.

### Dashboard

Everything that happened, spend and received together, filtered, sorted and edited in
place. Pinned under the app bar is a scrolling row of chips, each opening a sheet.

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

- **Tap any transaction** to open its actions sheet — amount, card, date, categories, over
  **Change category**, **Split** and **Delete**. Uncategorized rows are flagged in the
  error color. A split row's pill names its first category and counts the rest
  ("Grocery +2"); the sheet lists them all with their amounts.
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

### Settings

The second destination on the navigation bar: **Merchants & defaults**, the update controls
(automatic check, check now, install), and version information. Leaving it reloads the
ledger, because a default changed there can be backfilled over history — without the
reload the rows behind it would keep showing the categories they had on the way in.

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

It also covers the dashboard and split logic — `applyFilters`, `amountIn`,
`spendByCategory`, `categoryOptions`, `merchantOptions`, `pruneSelection`, `sortEntries`,
the split arithmetic (`unallocated`, `isBalanced`, `withRemainderInLast`) and the tombstone
payload (`encodeSplits`, `decodeSplits`). All are pure top-level functions precisely so
they can be tested without a database behind them; anything worth covering is written that
way.

Cases specifically guarding regressions this design invites: a split found by the category
of its *smallest* line (proving the filter reads lines rather than the cached
`category_id`), a category offered by the facet only because it appears as a minor split
line, a facet ignoring its own selection so it cannot empty itself, an amount sort reading
the filtered portion of a split rather than the whole charge, oldest-first breaking its ties
oldest-first so it is a true reverse of newest-first, ten paise divided three ways staying
balanced, and the last line absorbing that drift so what is stored sums exactly.

The database and widget layers have no automated coverage: `AppDatabase` needs the real
sqflite plugin, and `sqflite_common_ffi` is deliberately not a dependency. Delete, restore,
splits, the migrations and the scan watermark are verified by hand, below.

To exercise the live path end to end on an emulator:

```bash
# one per confirmed template; the issuer text is captured verbatim, never matched on
adb emu sms send BANKSMS "INR 204.00 spent on BANK Card X2858 @UPI_GEORGE EGG CENTRE 13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08"
adb emu sms send BANKSMS "Spent Rs.122.02 On BANK Card 6824 At INNOVATIVE RETAIL CONC On 2026-08-13:07:19:26."
adb emu sms send BANKSMS "INR 160.00 spent using BANK Card XX8008 on 11-Aug-26 on AMAZON PAY IN G. Avl Limit: INR 3,99,614.00."
```

The transaction should appear on the dashboard within a second or two. Newlines don't
survive `adb emu sms send`, so for the one-field-per-line transfer alerts use
the **Paste an SMS** button instead. To inspect what was actually stored:

```bash
adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/e.db
sqlite3 /tmp/e.db "SELECT t.amount, t.merchant, t.direction, t.reference, c.name FROM transactions t JOIN categories c ON c.id = t.category_id;"
sqlite3 /tmp/e.db "PRAGMA user_version; SELECT * FROM app_meta; SELECT * FROM deleted_transactions;"
sqlite3 /tmp/e.db "SELECT s.transaction_id, c.name, s.amount FROM transaction_splits s JOIN categories c ON c.id = s.category_id ORDER BY s.transaction_id, s.position;"
sqlite3 /tmp/e.db "SELECT merchant_name, category_id FROM merchant_mappings;"
```

Worth walking by hand, since none of it is covered by `flutter test`:

- **Upgrade, not reinstall.** Install the previous build, scan a few alerts, then
  install this one over the top: the rows must survive and `user_version` must read 5.
  Worth doing from a v3-created database too, since the `splits_json` `ALTER` is guarded
  on `oldVersion >= 3` and a v2-or-earlier database must *not* take that branch.
- **Split adds up.** Split a ₹2,000 charge: the balance must flow into the last row as the
  ones above it are filled, Save must stay disabled while it is unbalanced or a row has no
  category, and the stored lines must sum to the charge exactly
  (`SELECT SUM(amount) FROM transaction_splits WHERE transaction_id = ?`).
- **Split survives delete.** Delete a split transaction, confirm `splits_json` on its
  tombstone holds the lines, restore it, and confirm all of them come back. Then rescan-all
  and confirm nothing duplicates.
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

The database filename is still `expense_manager.db` — it predates the rename and is left
alone deliberately, since `getDatabasesPath()` resolves it under whatever the current
`applicationId` is. The `applicationId` itself moved from `com.example.expense_manager` to
`com.tu.expense.manager`, so a device carrying the old build will show both apps side by
side; uninstall the old one to drop its ledger.

## Limitations

- **Foreground only.** The listener runs with `listenInBackground: false`, so alerts
  that arrive while the app is closed are not seen until the next launch — which now
  catches up automatically, so the gap is invisible unless you never open the app.
  Background delivery needs a top-level `@pragma('vm:entry-point')` handler with its own
  database connection.
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
