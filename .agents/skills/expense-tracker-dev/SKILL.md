---
name: expense-tracker-dev
description: Architecture, database, parsing, and testing workflows for the TU Expense Tracker project.
---

# TU Expense Tracker Developer Guide

This skill covers the project structure, design invariants, database schema, SMS parsing rules, and command workflows to guide development and maintenance.

---

## 1. Project Structure

The project is structured as a multi-platform Flutter app and a Dart CLI server:

- **`lib/src/core/`**: Shared core domain logic, parsers, and models (pure Dart).
- **`lib/src/ui_shared/`**: Shared UI components and formatting rules shared between mobile and web.
- **`lib/src/mobile/`**: Mobile-specific shell (`HomeShell`), database wrappers, and screens (e.g., `AddTransactionScreen`).
- **`lib/src/web/`**: Web-specific shells and views.
- **`server/`**: A standalone backend server written in Dart (using Shelf).
- **`test/`**: Unit, widget, and integration tests.

---

## 2. Invariants & Ingestion Rules

- **Idempotency**: All ingestion is idempotent. Transactions have a natural key: `(amount, merchant, date, direction, reference)`. Duplicate natural keys are ignored or treated as conflicts.
- **Tombstones**: Deletions write natural keys to `deleted_transactions`. Inbox rescans check this table to avoid re-importing deleted SMS alerts.
- **SMS Parsing**:
  - **No Keyword Scanning for Direction**: Transaction direction (debit vs. credit) comes strictly from the matched regex template, not keyword scans (prevents issues with merchant names containing words like "CREDIT").
  - **No Clock Time Fallback**: UPI alerts have no clock time; the parser adopts the SMS arrival time if it falls on the same date, otherwise defaulting to midnight.
- **Notes**: Notes are sanitized using `cleanNote()`, collapsing white space and capping notes at 140 characters (`kNoteMaxLength`).

---

## 3. Database Schema Reference

SQLite database runs on version 7:
- `categories`: Available expense categories.
- `merchant_mappings`: Direct `merchant_name` (PK, NOCASE) to `category_id` mapping.
- `name_aliases`: Merged merchant or payment type labels.
- `transactions`: Core transaction records.
- `transaction_splits`: Category & amount breakdown lines for split transactions.
- `deleted_transactions`: Tombstone keys.
- `app_meta`: Persistent metadata (e.g., `last_scanned_sms_date`).

> [!NOTE]
> For split transactions, `transactions.category_id` is a denormalized cache storing the ID of the split line with the highest amount. This dominant category is used for fallback sorting and display.

---

## 4. Common Commands & Workflows

### Testing
- Run all tests: `flutter test`
- Run specific test: `flutter test test/add_transaction_test.dart`

> [!TIP]
> When writing widget tests for forms or scrollable bottom sheets, the default 800x600 test viewport will cause clipping and tap failures. Set a taller viewport size in widget tests:
> ```dart
> tester.view.physicalSize = const Size(800, 1600);
> tester.view.devicePixelRatio = 1.0;
> addTearDown(() => tester.view.resetPhysicalSize());
> ```

### Building & Running on Android Emulators
1. **List emulators**: `android emulator list`
2. **Start emulator**: `android emulator start <name>` (e.g., `cmd_phone_1`)
3. **Build APK**: `flutter build apk --debug`
4. **Install APK**: `android install --apks=build/app/outputs/flutter-apk/app-debug.apk --device=emulator-5554`
5. **Launch Application**: Use adb shell with monkey:
   `/Users/jay/Library/Android/sdk/platform-tools/adb -s emulator-5554 shell monkey -p com.tu.expense.manager -c android.intent.category.LAUNCHER 1`
