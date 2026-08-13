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
                                          tap an uncategorized row
                                                               ▼
                                            save mapping + backfill history
```

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

Schema version 2. Three tables, created on first launch (`AppDatabase`):

```sql
categories        (id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
merchant_mappings (merchant_name TEXT PK COLLATE NOCASE, category_id INTEGER FK)
transactions      (id INTEGER PK, amount REAL, payment_type TEXT,
                   merchant TEXT COLLATE NOCASE, date INTEGER, category_id INTEGER FK,
                   direction TEXT DEFAULT 'debit', reference TEXT DEFAULT '')
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
- Seed categories: Uncategorized, Grocery, Food, Fuel, Shopping, Bills & Utilities,
  Travel, Entertainment, Health. New ones can be added from the picker.

#### Migration v1 → v2

`onUpgrade` adds `direction` and `reference`, then drops and recreates the natural-key
index over the wider tuple. Every v1 row predates any notion of spend-vs-receive, so it
is a debit with no reference — exactly what the two column defaults supply, which is
why no backfill statement is needed.

### Categorization

On insert, the merchant is looked up in `merchant_mappings`. A hit uses that category;
a miss falls back to `Uncategorized`.

When you pick a category for a merchant, both writes happen in a single SQL
transaction, so a mapping can never be saved without its backfill:

1. upsert `merchant_mappings` (merchant → category)
2. `UPDATE transactions SET category_id = ? WHERE merchant = ?`

The row count from step 2 is what the confirmation snackbar reports.

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

- **Grant SMS permission** on first launch to receive alerts live.
- **Scan SMS inbox** (toolbar) imports matching alerts already on the device.
- **Add SMS** (FAB) pastes a message straight into the parser — prefilled with a
  sample, so the whole pipeline can be exercised without SMS permission.
- **Tap any transaction** to set its category. Uncategorized rows are flagged in the
  error color; any row can be tapped to correct a wrong category.

The header shows **Total spent** always, and adds **Received** plus **Net** once any
credit has been recorded. The category breakdown counts debits only — a refund is not
spending. Credit rows carry a `+` and a green amount in the list.

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

To exercise the live path end to end on an emulator:

```bash
# one per confirmed template; the issuer text is captured verbatim, never matched on
adb emu sms send BANKSMS "INR 204.00 spent on BANK Card X2858 @UPI_GEORGE EGG CENTRE 13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08"
adb emu sms send BANKSMS "Spent Rs.122.02 On BANK Card 6824 At INNOVATIVE RETAIL CONC On 2026-08-13:07:19:26."
adb emu sms send BANKSMS "INR 160.00 spent using BANK Card XX8008 on 11-Aug-26 on AMAZON PAY IN G. Avl Limit: INR 3,99,614.00."
```

The transaction should appear on the dashboard within a second or two. Newlines don't
survive `adb emu sms send`, so for the one-field-per-line transfer alerts use the
**Add SMS** FAB and paste the body instead. To inspect what was actually stored:

```bash
adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/e.db
sqlite3 /tmp/e.db "SELECT t.amount, t.merchant, t.direction, t.reference, c.name FROM transactions t JOIN categories c ON c.id = t.category_id;"
```

The database filename is still `expense_manager.db` — it predates the rename and is left
alone deliberately, since `getDatabasesPath()` resolves it under whatever the current
`applicationId` is. The `applicationId` itself moved from `com.example.expense_manager` to
`com.tu.expense.manager`, so a device carrying the old build will show both apps side by
side; uninstall the old one to drop its ledger.

## Limitations

- **Foreground only.** The listener runs with `listenInBackground: false`, so alerts
  that arrive while the app is closed are missed until the next inbox scan. Background
  delivery needs a top-level `@pragma('vm:entry-point')` handler with its own database
  connection.
- **Six of the ten templates are unconfirmed.** Everything under the "Unconfirmed"
  table was written from wording common across issuers rather than from a real message,
  so the exact phrasing may be wrong. A template that doesn't match simply means the
  message is ignored rather than mis-parsed, so the failure mode is a missing
  transaction, not a wrong one.
- **No credit alert has been seen yet.** All three credit templates are guesses. Paste
  a real one through the FAB to check it lands under "Received".
- **Unmatched messages are silent.** There is no diagnostics view listing bodies that
  look like money but matched no template, so a wrong guess above is invisible until
  you notice a transaction missing.
- Flutter warns that `another_telephony` applies the Kotlin Gradle Plugin, which future
  Flutter versions will reject. It builds today, but that dependency is on a clock.
