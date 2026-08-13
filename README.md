# TU Expense Tracker

An Android app that turns YES Bank credit card SMS alerts into a categorized expense
ledger. It parses incoming spend alerts, stores them in a local SQLite database, and
learns a merchant → category mapping so that categorizing a merchant once applies to
every past *and* future transaction from that merchant.

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

### The SMS format

```
INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE
13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08. SMS BLKCC 2858 to 9840909000 if not you
```

Four fields are extracted by regex (`SmsParser` in `lib/main.dart`):

| Field | Pattern | Result |
|---|---|---|
| Amount | `(?:INR\|Rs\.?)\s*([\d,]+\.\d{2})` | `204.00` |
| Payment type | `(?:spent on\|debited from)\s+(.*?)\s+@` | `YES BANK Card X2858` |
| Merchant | `@(.*?)\s+\d{2}-\d{2}-\d{4}` | `UPI_GEORGE EGG CENTRE` |
| Date | `(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2}\s+[am\|pmAM\|PM]+)` | `13-08-2026 09:21:35 am` |

Notes on the patterns:

- The amount uses `firstMatch`, so it takes the charge and not the trailing
  `Avl Lmt INR 281,496.08`. Order matters here.
- The date pattern's `[am|pmAM|PM]+` is a character class, not an alternation — it
  matches any run of those characters. It works on this format; `(?:am|pm|AM|PM)` is
  the stricter equivalent.
- Timestamps are converted by hand rather than with `DateFormat`, so lowercase `am`
  and uppercase `AM` both parse with no locale data initialization. 12 am maps to
  `00:00` and 12 pm to `12:00`.
- `parse()` returns `null` when a message doesn't match, which is how OTPs, promos
  and statement alerts are filtered out.

### Database

Three tables, created on first launch (`AppDatabase`):

```sql
categories        (id INTEGER PK, name TEXT UNIQUE COLLATE NOCASE)
merchant_mappings (merchant_name TEXT PK COLLATE NOCASE, category_id INTEGER FK)
transactions      (id INTEGER PK, amount REAL, payment_type TEXT,
                   merchant TEXT COLLATE NOCASE, date INTEGER, category_id INTEGER FK)
```

- `date` is stored as epoch milliseconds.
- `COLLATE NOCASE` on the merchant columns means `Swiggy` and `SWIGGY` resolve to one
  mapping, while the original casing is still what gets displayed.
- A `UNIQUE (amount, merchant, date)` index makes ingestion idempotent — re-scanning
  the inbox or receiving a duplicate broadcast can't create a second row.
- Seed categories: Uncategorized, Grocery, Food, Fuel, Shopping, Bills & Utilities,
  Travel, Entertainment, Health. New ones can be added from the picker.

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

## Testing

```bash
flutter analyze
flutter test
```

`test/widget_test.dart` covers the parser: the reference message, thousands
separators, pm times, the 12 am/12 pm boundaries, the `debited from` variant, and
rejection of non-spend messages.

To exercise the live path end to end on an emulator:

```bash
adb emu sms send YESBNK "INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE 13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08"
```

The transaction should appear on the dashboard within a second or two. To inspect what
was actually stored:

```bash
adb shell run-as com.tu.expense.manager cat databases/expense_manager.db > /tmp/e.db
sqlite3 /tmp/e.db "SELECT t.amount, t.merchant, c.name FROM transactions t JOIN categories c ON c.id = t.category_id;"
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
- **One SMS format.** The patterns target YES Bank card alerts. Other issuers need
  their own patterns; `parse()` returning `null` means unmatched messages are ignored
  rather than mis-parsed.
- Flutter warns that `another_telephony` applies the Kotlin Gradle Plugin, which future
  Flutter versions will reject. It builds today, but that dependency is on a clock.
