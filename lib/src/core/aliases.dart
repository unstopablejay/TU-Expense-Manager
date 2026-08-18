/// Folding the several spellings a bank uses for one merchant or card into a
/// single name.
///
/// Applied when rows are *read*, never by rewriting them — which is what lets a
/// later alert in the old spelling fold in by itself, and what makes a merge
/// undoable.
library;

import 'models.dart';


/// The two kinds of name a ledger row carries that the banks spell
/// inconsistently, and that can therefore be merged.
enum NameKind {
  merchant('merchant', 'merchant', 'merchants'),
  card('payment_type', 'card / account', 'cards & accounts');

  const NameKind(this.column, this.label, this.plural);

  /// The `kind` written into `name_aliases`, which is also the column it names.
  final String column;

  /// What to call this in a sentence. Spelled out rather than pluralised by
  /// appending an s, which turns "card / account" into "card / accounts".
  final String label;
  final String plural;
}

/// Which labels have been agreed to mean the same thing.
///
/// Resolution is always a single hop. Merging into a name that is itself a
/// merge result re-points the older rows rather than chaining onto them (see
/// [mergePlan]), so there is never a path to follow and never a cycle to
/// guard against.
class NameAliases {
  const NameAliases(this._byKind);

  /// Nothing merged. The state every database starts in.
  static const NameAliases empty = NameAliases(<NameKind, Map<String, String>>{});

  /// alias → canonical, per kind. Aliases are compared case-insensitively, to
  /// match the `COLLATE NOCASE` on the column, so keys are held lower-cased.
  final Map<NameKind, Map<String, String>> _byKind;

  /// Builds from raw `name_aliases` rows.
  factory NameAliases.fromRows(List<Map<String, Object?>> rows) {
    final map = <NameKind, Map<String, String>>{};
    for (final Map<String, Object?> row in rows) {
      final String kindName = row['kind'] as String;
      final NameKind? kind = NameKind.values
          .where((NameKind k) => k.column == kindName)
          .firstOrNull;
      // A kind this build does not know about is skipped rather than crashing
      // the whole ledger load.
      if (kind == null) continue;
      (map[kind] ??= <String, String>{})[(row['alias'] as String).toLowerCase()] =
          row['canonical'] as String;
    }
    return NameAliases(map);
  }

  /// What [raw] is called now, or [raw] itself if it has not been merged.
  String resolve(NameKind kind, String raw) =>
      _byKind[kind]?[raw.toLowerCase()] ?? raw;

  /// Every label folded into [canonical], including [canonical] itself.
  ///
  /// This is what a query has to expand to when it needs the *stored* rows
  /// behind a merged name.
  Set<String> membersOf(NameKind kind, String canonical) => <String>{
        canonical,
        ...?_byKind[kind]
            ?.entries
            .where((MapEntry<String, String> e) => e.value == canonical)
            .map((MapEntry<String, String> e) => e.key),
      };

  /// The alias rows for [kind], as stored. Lower-cased keys.
  Map<String, String> rowsFor(NameKind kind) =>
      Map<String, String>.unmodifiable(
          _byKind[kind] ?? const <String, String>{});

  /// Canonical names that have something folded into them — what the "Merged"
  /// section lists.
  ///
  /// How many labels each covers is deliberately not answered here: one alias
  /// row can stand for two stored spellings that differ only in case, so the
  /// honest count comes from the ledger, not from this table.
  List<String> mergedNames(NameKind kind) =>
      (_byKind[kind]?.values.toSet().toList() ?? <String>[])..sort();
}

/// The alias rows for one kind after folding [members] into [newName].
///
/// Takes and returns the whole `alias → canonical` map so the rewrite is one
/// pure step the caller can simply save.
///
/// Two rules keep resolution single-hop:
///  * anything already pointing at one of [members] is re-pointed at
///    [newName] — merging a merge must carry its earlier members along, or
///    they would surface again the moment their canonical stopped existing;
///  * a row that says nothing — the alias and the canonical are the same
///    string — is dropped. Note that `rapido → RAPIDO` is *not* one of those:
///    keys are lower-cased, so that row is what holds the chosen spelling
///    against the other casing of it.
Map<String, String> mergePlan(
  Map<String, String> existing,
  Set<String> members,
  String newName,
) {
  final Set<String> lowerMembers =
      members.map((String m) => m.toLowerCase()).toSet();
  final plan = <String, String>{};

  for (final MapEntry<String, String> row in existing.entries) {
    // Re-point rather than leave a hop behind.
    final bool pointsAtMerged = lowerMembers.contains(row.value.toLowerCase());
    plan[row.key] = pointsAtMerged ? newName : row.value;
  }
  for (final String member in members) {
    plan[member.toLowerCase()] = newName;
  }

  plan.removeWhere((String alias, String canonical) => alias == canonical);
  return plan;
}

/// Applies [aliases] to every row, then folds merchant spellings that differ
/// only in case onto the most common one.
///
/// A list-level pass rather than a per-row one because "most common spelling"
/// is a fact about the whole ledger. The case fold is not cosmetic: the
/// database already treats `RAPIDO` and `Rapido` as one merchant — the column
/// and the mappings key are both COLLATE NOCASE — so leaving the two apart in
/// Dart means the filter offers a choice the rest of the system cannot honour.
///
/// The stored spellings are kept on [ExpenseTxn.rawMerchant] and
/// [ExpenseTxn.rawPaymentType], because they are still the key that finds the
/// row again.
List<ExpenseTxn> canonicaliseLedger(
  List<ExpenseTxn> rows,
  NameAliases aliases,
) {
  // Tally the post-alias merchant spellings before rewriting anything, so the
  // winner is decided over the whole ledger rather than row by row.
  final counts = <String, Map<String, int>>{};
  for (final ExpenseTxn t in rows) {
    final String merchant = aliases.resolve(NameKind.merchant, t.merchant);
    final byCase = counts[merchant.toLowerCase()] ??= <String, int>{};
    byCase[merchant] = (byCase[merchant] ?? 0) + 1;
  }

  final display = <String, String>{
    for (final MapEntry<String, Map<String, int>> group in counts.entries)
      group.key: (group.value.entries.toList()
            // Count first; alphabetical only to break a tie, so the result
            // does not depend on the order rows came back in.
            ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
              final int byCount = b.value.compareTo(a.value);
              return byCount != 0 ? byCount : a.key.compareTo(b.key);
            }))
          .first
          .key,
  };

  return <ExpenseTxn>[
    for (final ExpenseTxn t in rows)
      t.copyWith(
        merchant: display[
            aliases.resolve(NameKind.merchant, t.merchant).toLowerCase()],
        paymentType: aliases.resolve(NameKind.card, t.paymentType),
      ),
  ];
}

/// Groups of [names] that look like the same thing under different labels.
///
/// Only ever a suggestion — groups are offered pre-ticked and merged solely on
/// a confirmation, because both heuristics can be wrong: two genuinely
/// different cards can end in the same four digits, and two merchants can
/// squash to the same letters.
///
/// Singletons are not groups, so anything that matched nothing is left out.
List<List<String>> suggestGroups(List<String> names, NameKind kind) {
  final groups = <String, List<String>>{};
  for (final String name in names) {
    final String? key = _suggestionKey(name, kind);
    if (key == null) continue;
    (groups[key] ??= <String>[]).add(name);
  }

  final List<List<String>> out = groups.values
      .where((List<String> group) => group.length > 1)
      .map((List<String> group) => group..sort())
      .toList()
    ..sort((List<String> a, List<String> b) => a.first.compareTo(b.first));
  return out;
}

/// What two labels have to share to be worth suggesting, or null when a name
/// offers nothing to match on.
String? _suggestionKey(String name, NameKind kind) {
  switch (kind) {
    case NameKind.card:
      // The trailing digits are the account. Everything in front of them is
      // the part the templates disagree about — `BANK A/c XX0444`,
      // `HDFC Bank A/C *0444` and `HDFC Bank A/c XX0444` share only the 0444.
      final RegExpMatch? tail =
          RegExp(r'(\d{3,})\D*$').firstMatch(name);
      return tail?.group(1);

    case NameKind.merchant:
      // Case, punctuation, spacing and a leading UPI tag are all noise a bank
      // adds inconsistently: `UPI_GEORGE EGG CENTRE` and `GEORGE EGG CENTRE`
      // are one shop.
      final String squashed = name
          .toLowerCase()
          .replaceFirst(RegExp(r'^upi[\s_-]+'), '')
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      return squashed.isEmpty ? null : squashed;
  }
}
