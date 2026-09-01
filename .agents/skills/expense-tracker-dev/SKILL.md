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
>
> 3. **Mandatory Visual Asset & Screenshot Synchronization Protocol**:
>    Whenever any UI component, screen layout, theme/palette, feature workflow, or Android installation/permission step is added, redesigned, or updated, **THE RELEVANT SCREENSHOTS IN `docs/screenshots/` AND THEIR REFERENCES IN `README.md` MUST BE IMMEDIATELY RE-CAPTURED AND UPDATED**:
>    - If a feature or UI page changes (e.g. Dashboard donut/charts, Transactions cards/filters, Split editor, Merchant Defaults, Themes/OLED), launch the Android Virtual Device (`emulator-5554`), seed realistic demo data, navigate to the screen, and capture fresh high-resolution screenshots.
>    - If installation, permission, or Play Protect handling flows change, re-capture or update the system walkthrough graphics (`install_play_protect.png`, `install_restricted_settings.png`, `install_sms_permission.png`, `install_app_info.png`).
>    - Never leave stale, outdated, or mismatched screenshots in `docs/screenshots/` or `README.md` after modifying UI or user-facing flows.

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
  - **Asynchronous Background Ingestion (`MainActivity.kt`)**: Native Android SMS and MMS/RCS queries run on a dedicated background worker executor (`Executors.newSingleThreadExecutor()`) with batch text part loading (`content://mms/part`), completely decoupling heavy inbox scans from the Android UI thread and Flutter rasterizer to prevent any UI freezing during rescans.
  - **Database-Level Composite Deduplication (`AppDatabase.insertParsed`)**:
    - **Exact Natural Key**: `(amount, merchant, date, direction, reference)`.
    - **Reference Code Uniqueness**: Non-empty reference codes (UPI Ref, UTR, Refno) deduplicate across identical `amount + direction + reference`.
    - **Time Window & Date Fallback Tolerance**: Empty-reference transactions deduplicate across identical `amount + merchant (NOCASE) + direction` within a ±60-second window. Same-day whole-day fallback deduplication applies only to date-only SMS alerts lacking an explicit clock time (`hasExplicitTime == false`). Transactions with explicit clock times (e.g. card alerts) outside the 60-second window are recognized as distinct same-day transactions.
- **Tombstones**: Deletions write natural keys to `deleted_transactions`. Inbox rescans check this table to avoid re-importing deleted SMS alerts.
- **SMS Parsing**:
  - **No Keyword Scanning for Direction**: Transaction direction (debit vs. credit) comes strictly from the matched regex template, not keyword scans (prevents issues with merchant names containing words like "CREDIT").
  - **Flexible Merchant Separators & Time Formats**: Templates flexibly match `@`, `at`, `to`, `towards`, and `for` merchant separators, with support for timestamps with or without seconds (`HH:mm[:ss]` and optional `am`/`pm`).
  - **No Clock Time Fallback**: UPI alerts have no clock time; the parser adopts the SMS arrival time if it falls on the same date, otherwise defaulting to midnight.
  - **Merchant Gateway Prefix Stripping (`cleanMerchantName`)**: Automatically strips bank gateway transport prefixes (`UPI_`, `UPI-`, `UPI/`, `UPI `) from raw merchant strings at SMS parse time while preserving original merchant casing and non-empty fallbacks.
- **Testing Safety Rule**: **NEVER test or install builds on real physical devices** (including CMF Phone 1 or any other device connected via wireless debugging or USB) because they hold real user financial data. **ALWAYS use an Android Virtual Device (VD emulator, e.g., `emulator-5554`) for all testing, verification, and inspection.**
- **Docker Environment Rule**: **STRICTLY use the local Docker server on your development machine.** **NEVER touch, connect to, or execute commands on the ZIMA OS Docker instance.**
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

## 4. UI Patterns, Multi-Theme System, Category Emojis & Cards

- **Category Emojis, Custom Icons & Multi-Style Icon Packs (`lib/src/ui_shared/palette.dart`, `categories_screen.dart`, `models.dart`)**:
  - **Vibrant WhatsApp / Fluent Style Category Emojis**: Every category has a colorful emoji representation. Defaults include 🛒 Grocery, 🍔 Food, ⛽ Fuel, 🛍️ Shopping, 💡 Bills & Utilities, ✈️ Travel, 🎬 Entertainment, 💊 Health, ❓ Uncategorized, 💰 Income/Savings, 🏦 Loans/EMI, 🥚 Egg, 🍗/🥩/🐟 Non-Veg/Meat/Fish, 👨 Papa/Family, 💄 Cosmetics/Beauty, 🥛 Milk/Dairy, 🍿 Snacks, and 🥗 Veggies/Fruits.
  - **Smart Automatic Keyword Matching & Legacy Fallback Upgrade (`suggestCategoryEmoji`, `categoryEmoji`, `categoryVectorIcon`)**: Automatically suggests contextual emojis and vector icons when typing category names (e.g. coffee/cafe -> ☕, loans/emi/debt -> 🏦, egg/anda/omelet -> 🥚, non-veg/chicken/biryani -> 🍗, meat/mutton -> 🥩, fish/seafood -> 🐟, papa/family/dad -> 👨, savings/deposit -> 💰, cosmetics/makeup -> 💄, milk/dairy -> 🥛, snacks/bakery -> 🍿, veggies/fruits/salad -> 🥗, rent/house -> 🏠, gym/fitness -> 🏋️, cab/uber -> 🚕, pet/dog -> 🐾, gaming/steam -> 🎮, books/college -> 📚, salon/hair -> ✂️, bills -> 💡, crypto/stocks -> 📈, etc.). `categoryEmoji()` automatically upgrades legacy fallback records (`icon == '🏷️'` or empty) to contextual emojis.
  - **Interactive Category Editor Sheet (`_CategoryEditorSheet`)**: Features a live squircle emoji avatar preview, real-time auto-suggestion based on input text, a curated quick-pick emoji selector grid (`kCuratedCategoryEmojis`), custom emoji text input, and full edit/rename support.
  - **End-to-End Category Icon Propagation (Mobile, Web & Shared UI)**: User-customized category icons saved in SQLite `categories.icon` are exported into JSON backup snapshots (`BackupData.categories`) and parsed by `SnapshotStore.fromBackup`. All shared and web views (`WebTransactionsView` category pills, `_FacetMenu` options, `_TransactionsSummary` breakdown chips, `_DashboardTabState` charts/ranked bars/table bodies, and `MerchantDefaultsScreen`) propagate `explicitIcon` to `CategoryAvatar` so custom category icons reflect consistently everywhere across both platforms.
  - **App Icon Packs (`AppIconPack`)**: Supports 3 distinct visual styles: `AppIconPack.emojis` (vibrant emoji avatars), `AppIconPack.outlined` (clean monochrome outline vector icons mapped via `categoryVectorIcon`), and `AppIconPack.filled` (modern solid filled vector icons). Configurable via `ThemeController.setIconPack()` and accessible in both Mobile Settings and the Web Appearance popup menu.
- **Modern Fintech Rounded Transaction Cards (`lib/src/ui_shared/transactions_tab.dart`)**:
  - **Copilot / Revolut Inspired Card Design**: 16px corner radius (`BorderRadius.circular(16)`), subtle outline border with elevation 0.
  - **Tinted Squircle Badges**: 44x44 tinted squircle avatar (`BorderRadius.circular(12)`) featuring a 15% alpha background tint of the category chart hue and 30% alpha outline border, enclosing a bold 22px category emoji (or `💰` for credits).
  - **Clear Typography & Directional Color**: Bold merchant titles, subtext for account & date metadata, 8px rounded category badge with border, and right-aligned bold amounts with explicit `+` (accent green) for credits and `-` for debits.
- **Multi-Theme & Pitch Black OLED Architecture (`lib/src/ui_shared/theme.dart`, `theme_models.dart`, `theme_controller.dart`)**:
  - **Two-Tier Customization**: Base mode (`AppThemeMode`: `system`, `light`, `dark`, `oled`) + Accent color palette (`AppAccentColor`: `blue`, `red`, `green`, `purple`, `orange`, `pink`, `cyan`, `amber`) + Icon Pack (`AppIconPack`: `emojis`, `outlined`, `filled`).
  - **Pitch Black OLED Mode**: Pure `#000000` pitch black scaffold, app bar, and bottom navigation bar backgrounds paired with `#121418` deep obsidian card and dialog containers, providing true black pixel shut-off for OLED displays while preserving structural visual hierarchy.
  - **State Management & Persistence**: `ThemeController` (singleton `ChangeNotifier`) automatically persists preferences via `ThemePrefs` (`theme.mode`, `theme.accent`, `theme.icon_pack`) and seamlessly synchronizes active theme across both Mobile (`TuExpenseTrackerApp`) and Web (`WebApp`, `WebShell`).
  - **Web Theme Menu & Branded Header (`WebShell._themeMenu`, `WebShell.appBar`)**: Features a branded app logo badge next to the title in the top app bar, alongside a dropdown menu providing instant switching for Theme Mode, Accent Color, and Icon Pack.
  - **Web Branding & Metadata**: Web build assets (`web/favicon.png`, `web/icons/Icon-*.png`, `assets/icon/app_icon.png`, `web/index.html`, `web/manifest.json`) are branded with the custom TU Expense Tracker app icon and metadata, replacing default Flutter placeholder assets.
- **Password Visibility Toggle**: All credential and password input fields (e.g. `_CredentialsDialog` on mobile and `LoginScreen` on web) must include an eye icon button (`IconButton`) toggling `obscureText` between masked and visible states.
- **Active Filter Display**: Filter selections are presented immediately as individual removable tokens in `ActiveFiltersBar`.
- **Visual Loading Modals & Coin Progress Bar (`lib/src/ui_shared/loading_dialog.dart`)**:
  - **`AnimatedCoin`**: Custom-rendered 3D rotating metallic currency coin with perspective projection and floating bob effect.
  - **`CoinProgressBar`**: Pill-shaped capsule progress track with animated multi-stop gradient shimmer sweep.
  - **`LoadingModal` & `withLoadingModal<T>()`**: Reusable non-dismissible modal dialog and async wrapper that provides clear visual feedback during blocking operations (initial SMS parsing, manual inbox rescans, database export/restore, server sync, authentication, and batch tombstone restores), ensuring clean dismissal in `finally` blocks upon completion or error.
  - **`LoadingOverlay`**: Scoped container-level loading overlay.

---

## 5. Database Schema Reference

SQLite database runs on version 9 (`kSchemaVersion = 9`):
- `categories`: Available expense categories (`id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL COLLATE NOCASE, icon TEXT NOT NULL DEFAULT ''`).
- `merchant_mappings`: Direct `merchant_name` (PK, NOCASE) to `category_id` mapping.
- `name_aliases`: Merged merchant or payment type labels.
- `transactions`: Core transaction records.
- `transaction_splits`: Category & amount breakdown lines for split transactions.
- `deleted_transactions`: Tombstone keys.
- `app_meta`: Persistent metadata (e.g., `last_scanned_sms_date`).

> [!NOTE]
> - In schema v8, the `icon` column stores custom category emojis. When empty, `categoryEmoji(name)` falls back to seeded emojis and smart keyword matching.
> - In schema v9, bank gateway transport prefixes (`UPI_`, `UPI-`, `UPI/`, `UPI `) are automatically stripped across `transactions`, `merchant_mappings`, `deleted_transactions`, and `name_aliases` during migration, with automatic collision resolution preserving non-UPI category mappings and deduplicating matching natural keys.
> - For split transactions, `transactions.category_id` is a denormalized cache storing the ID of the split line with the highest amount. This dominant category is used for fallback sorting and display.

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

### Automated Rolling Backup & Restore Architecture
- **Scheduled Auto-Backup**: `BackupScheduler` runs daily at 21:00 (9:00 PM) local container time (`TZ`), configurable via `BACKUP_HOUR` and `BACKUP_MINUTE` env vars.
- **Atomic Bundle & Rolling Retention**: `BackupManager` packages full server state (`users.json`, `sessions.json`, and all device subtrees) into `/data/backups/backup_<timestamp>.json`, enforcing a 10-slot rolling FIFO cap (oldest auto/manual snapshot deleted upon the 11th).
- **API Surface**:
  - `GET /api/v1/backups`: Lists snapshots and schedule status.
  - `POST /api/v1/backups`: Creates on-demand server snapshot.
  - `POST /api/v1/backups/<id>/restore`: Performs safe server state restoration.
- **Safety Shield on Restore**:
  - Server automatically creates a pre-restore safety copy (`safety_...`) before applying the archive.
  - Mobile app takes a local database safety export before overwriting local SQLite state with restored snapshot data.
  - Safety copies do not count towards the 10 rolling auto-save slots.
- **CLI Trigger**:
  ```bash
  docker exec -it tu-expense-server /app/server --backup-now
  ```

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

---

## 10. 📸 Visual Asset & Screenshot Capture Workflow

Whenever a UI redesign, new feature, theme update, or installation step changes, developers must update the screenshot assets in `docs/screenshots/` and update `README.md`.

### Screenshot Standards
- **Device & Environment**: Exclusively use the Android Virtual Device (e.g., `emulator-5554` / `cmd_phone_1`). **Never** connect or capture physical devices.
- **Theme**: Default to Dark Mode / Pitch Black OLED for visual consistency across documentation.
- **Sample Data**: Ensure realistic demo data (realistic merchant names, amounts, categories, and split rows) is seeded into the database before capturing so cards and charts look clean and professional.
- **Resolution**: Native device resolution (1080x2400 or crisp 1080px width).

### Capture Commands & Navigation
1. **Inspect UI Layout & Tap Coordinates**:
   ```bash
   android layout --device=emulator-5554
   ```
2. **Navigate & Tap Elements**:
   ```bash
   # Tap specific coordinates (e.g. Transactions tab)
   adb -s emulator-5554 shell input tap <X> <Y>
   ```
3. **Capture PNG Directly to `docs/screenshots/`**:
   ```bash
   # Capture active screen
   adb -s emulator-5554 exec-out screencap -p > docs/screenshots/<screen_name>.png
   ```

### Standard Screenshot Asset Index
| File Name | Screen / Purpose | Location in README |
| :--- | :--- | :--- |
| `dashboard.png` | Spend overview card, donut chart, category rank list | Visual Tour (Row 1) |
| `transactions.png` | Rounded cards, category badges, split indicators, search & filter chips | Visual Tour (Row 1) |
| `split_editor.png` | Multi-category split editor with remainder calculation | Visual Tour (Row 2) |
| `merchant_defaults.png` | Merchant category defaults (*Always ask me*, *Default*, *Not set*) | Visual Tour (Row 2) |
| `themes.png` | Theme mode selector, OLED toggle, accent color palette, icon packs | Visual Tour (Row 3) |
| `install_play_protect.png` | Play Protect dialog with expanded "More details" and "Install anyway" | Installation Guide (Step 2) |
| `install_restricted_settings.png` | App info screen with 3-dots menu open showing "Allow restricted settings" | Installation Guide (Step 3) |
| `install_sms_permission.png` | App permissions screen showing SMS permission set to Allow | Installation Guide (Step 4) |


### Multi-Month Comparison
The app features a full-screen `CompareMonthsScreen` that displays a side-by-side table of category spending across 2 to 6 selected months, along with delta columns (Δ amount and Δ %) for direct 2-month comparisons. The screen handles data from `spendByCategoryPerMonth`.
