/// The two things a restore asks the user before it touches anything.
library;

import 'package:flutter/material.dart';

/// Asks before a restore throws the current ledger away.
///
/// Both counts are named because they are the one thing that makes the question
/// answerable — restoring 1,190 transactions over 1,284 is a very different
/// proposition from restoring them over none, and only the user knows which of
/// the two they meant. False for a dismissed dialog, so a tap outside cancels.
Future<bool> confirmRestore(
  BuildContext context, {
  required int replacing,
  required int incoming,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: const Text('Restore from this backup?'),
        content: Text(
          replacing == 0
              ? 'This loads $incoming transactions. There is nothing in the '
                  'app to replace.'
              : 'This replaces all $replacing transactions currently in the '
                  'app with the $incoming in this file, along with their '
                  'categories, splits, merges and deleted rows.\n\n'
                  'A copy of what is here now is saved first, but nothing '
                  'else can undo it.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Shows why a file was refused, having touched nothing.
///
/// Long lists are truncated: a workbook broken in one place is usually broken
/// in a hundred, and a dialog listing all hundred says less than one listing
/// five and a count.
Future<void> showBackupProblems(
  BuildContext context,
  List<String> problems,
) {
  const int shown = 5;
  final List<String> visible = problems.take(shown).toList();
  final int rest = problems.length - visible.length;
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('This backup cannot be restored'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Nothing in the app has been changed.'),
            const SizedBox(height: 12),
            for (final String problem in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $problem'),
              ),
            if (rest > 0)
              Text(
                'and $rest more.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
