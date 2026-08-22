---
name: expense-tracker-dev
description: Architecture, database, parsing, and testing workflows for the TU Expense Tracker project.
---

# TU Expense Tracker Developer Guide

This skill covers the project structure, design invariants, database schema, SMS parsing rules, filter subsystem, Docker deployment, and developer workflows to guide development and maintenance.

---

> [!IMPORTANT]
> ### 📋 Mandatory Development Protocols
> 1. **Mandatory Documentation Synchronization Protocol**:
>    Whenever code changes, architectural enhancements, UI redesigns, database schema updates, or workflow improvements are made in this repository, **THEY MUST ALWAYS BE SYNCHRONIZED AND UPDATED IN BOTH**:
>    - **This developer skill (`.agents/skills/expense-tracker-dev/SKILL.md`)**
>    - **The project root documentation (`README.md`)**
>    Never leave the skill or `README.md` outdated after making feature additions or bug fixes.
>
> 2. **Mandatory Test-by-Default Protocol**:
>    Whenever any new feature, UI enhancement, architectural change, or bug fix is implemented, **IT MUST BE TESTED BY DEFAULT**:
>    - Add and update unit, widget, or integration tests covering all new logic, UI states, lifecycle hooks, and error handling.
>    - Always execute the full test suite (`flutter test`) and static analysis (`dart analyze`) to ensure a 100% pass rate and zero warnings.
>    - Never conclude a task or mark a feature complete without running and verifying the automated test suites.

---

## 1. Project Structure

The project is structured as a multi-platform Flutter app and a Dart CLI server:

- **`lib/src/core/`**: Shared core domain logic, parsers, models, and ledger view derivations (pure Dart, zero Flutter dependencies).
- **`lib/src/ui_shared/`**: Shared UI components, tokens, charts, formatting rules, and tabs (`DashboardTab`, `TransactionsTab`) shared between mobile and web.
- **`lib/src/mobile/`**: Mobile-specific shell (`HomeShell`), SQLite database (`AppDatabase`), screens, sync client, and background services.
- **`lib/src/web/`**: Web-specific shell (`WebShell`), desktop transactions table (`WebTransactionsView`), API client, and login screen.
- **`server/`**: Standalone backend server written in Dart (Shelf), storing JSON snapshots and queued edits.
- **`test/`**: Unit, widget, and integration tests across mobile and web shells.

---

## 2. Invariants & Ingestion Rules

- **Idempotency & Multi-Layer Deduplication**:
  - **SmsSource In-Memory Deduplication**: Tracks recent incoming SMS signatures in a bounded 60-second window to drop duplicate native broadcast events from multi-part SMS or carrier re-deliveries, and prevents duplicate telephony listener registrations.
  - **Sequential Ingestion Queue (`HomeShell._serializeSms`)**: Asynchronous serialization queue guarantees that live incoming SMS processing and batch inbox catch-up scans never execute concurrently or race.
  - **Database-Level Composite Deduplication (`AppDatabase.insertParsed`)**:
    - **Exact Natural Key**: `(amount, merchant, date, direction, reference)`.
    - **Reference Code Uniqueness**: Non-empty reference codes (UPI Ref, UTR, Refno) deduplicate across identical `amount + direction + reference`.
    - **Time Window & Date Fallback Tolerance**: Empty-reference transactions deduplicate across identical `amount + merchant (NOCASE) + direction` within a ±120-second window or across same-day arrival time fallbacks.
- **Tombstones**: Deletions write natural keys to `deleted_transactions`. Inbox rescans check this table to avoid re-importing deleted SMS alerts.
- **SMS Parsing**:
  - **No Keyword Scanning for Direction**: Transaction direction (debit vs. credit) comes strictly from the matched regex template, not keyword scans (prevents issues with merchant names containing words like "CREDIT").
  - **No Clock Time Fallback**: UPI alerts have no clock time; the parser adopts the SMS arrival time if it falls on the same date, otherwise defaulting to midnight.
- **Notes**: Notes are sanitized using `cleanNote()`, collapsing white space and capping notes at 140 characters (`kNoteMaxLength`).

---

## 3. Filter Architecture & Multi-Select Interlinked Facets

Filtering is centralized in `lib/src/core/ledger_view.dart` via `deriveLedgerView()`.

### Bidirectional Facet Interlinking
The available choices for each facet dynamically reflect the current state of **all other** active filters:
- **Months**: `monthOptions(transactions, current: currentMonth, keep: requested.months, categoryIds: requested.categoryIds, merchants: requested.merchants, paymentTypes: requested.paymentTypes)`
- **Categories**: `categoryOptions(transactions, allCategories, months: requested.months, merchants: requested.merchants, paymentTypes: requested.paymentTypes)`
- **Merchants**: `merchantOptions(transactions, months: requested.months, categoryIds: requested.categoryIds, paymentTypes: requested.paymentTypes)`
- **Cards / Accounts**: `paymentTypeOptions(transactions, months: requested.months, categoryIds: requested.categoryIds, merchants: requested.merchants)`

### Pruning Invariants
When filters change:
- `pruneSelection()` ensures multi-select sets (`categoryIds`, `merchants`, `paymentTypes`) only retain values that still exist in the constrained options.
- Month selections remain sticky and are preserved even across empty search queries.

### Shared Filter UI Controls (`lib/src/ui_shared/shared_controls.dart`)
- **`FilterTriggerButton`**: Renders trigger buttons with inactive ghost state and active light-blue pill state with count badges (`[1]`, `[2]`).
- **`ActiveFilterChipToken`**: Removable chip with subtle border, 11px font, and explicit `✕` close icon for each active selection.
- **`ActiveFiltersBar`**: Horizontal scrollable container for active chips with a right-aligned `Clear all` button.
- **`chooseMany`**: Reusable modal sheet supporting multi-select checkboxes for all facets.

---

## 4. UI Patterns & Form Fields

- **Password Visibility Toggle**: All credential and password input fields (e.g. `_CredentialsDialog` on mobile and `LoginScreen` on web) must include an eye icon button (`IconButton`) toggling `obscureText` between masked and visible states.
- **Active Filter Display**: Filter selections are presented immediately as individual removable tokens in `ActiveFiltersBar`.
- **Visual Loading Modals & Coin Progress Bar (`lib/src/ui_shared/loading_dialog.dart`)**:
  - **`AnimatedCoin`**: Custom-rendered 3D rotating metallic currency coin with perspective projection and floating bob effect.
  - **`CoinProgressBar`**: Pill-shaped capsule progress track with animated multi-stop gradient shimmer sweep.
  - **`LoadingModal` & `withLoadingModal<T>()`**: Reusable non-dismissible modal dialog and async wrapper that provides clear visual feedback during blocking operations (initial SMS parsing, manual inbox rescans, database export/restore, server sync, authentication, and batch tombstone restores), ensuring clean dismissal in `finally` blocks upon completion or error.
  - **`LoadingOverlay`**: Scoped container-level loading overlay.

---

## 5. Database Schema Reference

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

## 6. Docker & Multi-Platform Deployment

### Building & Running Local Docker Server
```bash
# Build the local server and web client
docker build -t tu-expense-server .

# Run container exposing port 8099
docker run -d \
  --name tu-expense-server \
  -p 8099:8099 \
  -v tu-expense-data:/data \
  -e EXPENSE_ADMIN_USER=jay \
  -e EXPENSE_ADMIN_PASSWORD=adminpassword123 \
  tu-expense-server:latest
```

### Network Bridging: Android Emulator to Host Docker
> [!IMPORTANT]
> When connecting the Android Virtual Device (VD) to Docker on Mac/PC:
> - **Do NOT use `localhost`** (it routes to the Android emulator itself).
> - Use the Android emulator loopback alias: **`http://10.0.2.2:8099`** or the Mac's LAN IP (e.g., `http://192.168.1.x:8099`).

---

## 7. Developer Workflows & Commands

### Testing & Static Analysis
- Run all tests: `flutter test`
- Run static analysis: `dart analyze`
- Run specific test: `flutter test test/web_shell_test.dart`

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
3. **Build debug APK**: `flutter build apk --debug`
4. **Install APK**: `/Users/jay/Library/Android/sdk/platform-tools/adb -s emulator-5554 install -r build/app/outputs/flutter-apk/app-debug.apk`
5. **Launch Application**:
   ```bash
   /Users/jay/Library/Android/sdk/platform-tools/adb -s emulator-5554 shell monkey -p com.tu.expense.manager -c android.intent.category.LAUNCHER 1
   ```

### Emulator Database Inspection & Seeding
Directly query or seed the isolated SQLite database on an Android emulator:
```bash
# Query categories
adb -s emulator-5554 shell "run-as com.tu.expense.manager sqlite3 databases/expense_manager.db 'SELECT * FROM categories;'"

# Query transactions count
adb -s emulator-5554 shell "run-as com.tu.expense.manager sqlite3 databases/expense_manager.db 'SELECT COUNT(*) FROM transactions;'"

# Seed SQL file from host to emulator DB
adb -s emulator-5554 push seed.sql /data/local/tmp/seed.sql
adb -s emulator-5554 shell "run-as com.tu.expense.manager sqlite3 databases/expense_manager.db < /data/local/tmp/seed.sql"
```
