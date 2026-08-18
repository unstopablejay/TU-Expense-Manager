/// Constants both the app and the web build need.
///
/// They live in their own file, with no imports at all, because everything else
/// under `core/` may depend on them and nothing may depend on a platform.
/// `AppDatabase` re-exposes the first two under its own names, so the README and
/// anything reading `AppDatabase.uncategorized` keeps working.
library;

/// The category every uncategorized row is filed under, and the one category
/// that cannot be deleted. Compared case-insensitively wherever it is used.
const String kUncategorized = 'Uncategorized';

/// The database schema this build understands. A backup or snapshot stamped
/// with a *higher* number is refused rather than imported — it may hold columns
/// this build has never heard of.
const int kSchemaVersion = 7;

/// The longest note that is stored. Generous for the sentence a note actually
/// is, and short enough that no single one can dominate the tile it annotates.
const int kNoteMaxLength = 140;

/// Paise. Amounts are doubles, so three ways through ₹0.10 cannot land exactly;
/// anything under half a paisa is a rounding artefact rather than a real gap.
const double kSplitTolerance = 0.005;
