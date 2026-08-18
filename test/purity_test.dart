// Guards the boundary the web build depends on.
//
// `lib/src/core/` is pure Dart and `lib/src/ui_shared/` is Flutter plus two
// pure-Dart packages. Neither may reach for sqflite, dart:io, the SMS plugin or
// anything else with no web implementation — that is the whole reason the app's
// dashboard and transactions screens can be compiled for a browser at all.
//
// The check is a lint on import directives rather than a compile, because a
// compile only fails once something actually calls the offending code. An import
// is the moment the boundary is crossed, and it is the moment to fail.
//
// **This is transitively closed by induction.** Neither directory may import
// anything outside itself plus a fixed allowlist of known-web-safe packages, and
// every file in both directories is checked. So no path of any length can reach
// a platform library: the first hop off the allowlist is a failure here. That
// argument is why this cheap test is worth as much as a web build, and it stops
// holding the moment someone adds a directory to the allowlist without checking
// what that directory imports.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Dart's own libraries that carry no platform assumptions.
///
/// `dart:io` is the conspicuous absence, and `dart:html`/`dart:js` are absent
/// from the other direction — a core file must not assume a browser either.
const Set<String> _safeDartLibraries = <String>{
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:math',
  'dart:typed_data',
  'dart:ui',
};

/// Packages with a real web implementation, checked against pubspec.lock.
///
/// `intl` and `fl_chart` are pure Dart with no plugin block at all. `flutter`
/// itself is fine in `ui_shared/` and banned in `core/` — see [_allowed].
const Set<String> _safePackages = <String>{
  'flutter',
  'fl_chart',
  'intl',
};

/// What each guarded directory may import, beyond its own siblings.
Set<String> _allowed(String dir) => switch (dir) {
      // No Flutter at all. A widget in core would be a widget the web build
      // could not avoid dragging a platform behind.
      'core' => _safeDartLibraries.difference(<String>{'dart:ui'}),
      'ui_shared' => _safeDartLibraries,
      _ => throw ArgumentError('no rule for lib/src/$dir'),
    };

/// Which sibling directories a guarded directory may import from.
Set<String> _reachable(String dir) => switch (dir) {
      'core' => <String>{'core'},
      'ui_shared' => <String>{'core', 'ui_shared'},
      _ => throw ArgumentError('no rule for lib/src/$dir'),
    };

/// Every `import` or `export` target in [source], comments and strings aside.
///
/// Deliberately a regex over the text rather than a parse: the analyzer already
/// resolves these, so what is wanted here is something that cannot itself fail
/// to notice a directive.
List<String> importsOf(String source) {
  final RegExp directive = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  return directive
      .allMatches(source)
      .map((RegExpMatch m) => m.group(1)!)
      .toList();
}

/// The problem with [target] imported from a file in `lib/src/[dir]`, or null.
String? problemWith(String target, String dir) {
  if (target.startsWith('dart:')) {
    return _allowed(dir).contains(target)
        ? null
        : '$target is not web-safe';
  }

  if (target.startsWith('package:')) {
    final String name = target.substring('package:'.length).split('/').first;

    // A package: self-reference into our own lib, which the relative-path rule
    // below governs. Normalise it rather than treating it as a third party.
    if (name == 'tu_expense_tracker') {
      final String path = target.split('/').skip(1).join('/');
      if (!path.startsWith('src/')) {
        return 'reaches back out to lib/${path.isEmpty ? '' : path} — '
            'core and ui_shared must not depend on the app entrypoint';
      }
      final String other = path.split('/')[1];
      return _reachable(dir).contains(other)
          ? null
          : 'lib/src/$dir must not import lib/src/$other';
    }

    if (!_safePackages.contains(name)) {
      return 'package:$name has no verified web implementation';
    }
    if (name == 'flutter' && dir == 'core') {
      return 'lib/src/core must stay pure Dart, with no Flutter';
    }
    return null;
  }

  // A relative path. Anything that climbs out of lib/src is a crossing too.
  if (target.startsWith('../')) {
    final List<String> parts = target.split('/');
    // '../<dir>/file.dart' from lib/src/<dir>/ lands in lib/src/<other>/.
    if (parts.length >= 3 && parts[0] == '..') {
      final String other = parts[1];
      return _reachable(dir).contains(other)
          ? null
          : 'lib/src/$dir must not import lib/src/$other';
    }
    return 'climbs out of lib/src: $target';
  }

  // A plain sibling filename, which is always within the same directory.
  return null;
}

void main() {
  group('the web-safe boundary', () {
    for (final String dir in <String>['core', 'ui_shared']) {
      final Directory root = Directory('lib/src/$dir');

      test('lib/src/$dir imports only what the web can compile', () {
        if (!root.existsSync()) {
          // ui_shared arrives a few commits after core. An absent directory is
          // not a pass, so say which one it was.
          markTestSkipped('lib/src/$dir does not exist yet');
          return;
        }

        final List<File> files = root
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));

        expect(
          files,
          isNotEmpty,
          reason: 'lib/src/$dir exists but holds no Dart — the guard would '
              'pass by having nothing to check',
        );

        final List<String> violations = <String>[];
        for (final File file in files) {
          final String source = file.readAsStringSync();
          for (final String target in importsOf(source)) {
            final String? problem = problemWith(target, dir);
            if (problem != null) {
              violations.add('${file.path}: $problem');
            }
          }
        }

        expect(
          violations,
          isEmpty,
          reason: 'These imports would break the web build:\n'
              '  ${violations.join('\n  ')}\n\n'
              'Either move the code to lib/src/mobile, or — if the package '
              'genuinely has a web implementation — add it to _safePackages '
              'and say in the commit how that was verified.',
        );
      });
    }

    // The rules themselves, so a mistake in the guard shows up as a failing
    // test rather than as a guard that quietly permits everything.
    test('the rules reject what they are meant to reject', () {
      expect(problemWith('dart:io', 'core'), isNotNull);
      expect(problemWith('dart:io', 'ui_shared'), isNotNull);
      expect(problemWith('package:sqflite/sqflite.dart', 'core'), isNotNull);
      expect(
        problemWith('package:another_telephony/telephony.dart', 'ui_shared'),
        isNotNull,
      );
      expect(problemWith('package:path_provider/path_provider.dart', 'core'),
          isNotNull);
      expect(problemWith('package:flutter/material.dart', 'core'), isNotNull,
          reason: 'core must be pure Dart');
      expect(problemWith('../mobile/database.dart', 'core'), isNotNull);
      expect(problemWith('../mobile/database.dart', 'ui_shared'), isNotNull);
      expect(problemWith('../ui_shared/palette.dart', 'core'), isNotNull,
          reason: 'core must not depend on widgets');
      expect(problemWith('package:tu_expense_tracker/main.dart', 'core'),
          isNotNull,
          reason: 'the barrel drags the whole app in');
    });

    test('the rules accept what they are meant to accept', () {
      expect(problemWith('dart:convert', 'core'), isNull);
      expect(problemWith('dart:math', 'core'), isNull);
      expect(problemWith('package:intl/intl.dart', 'core'), isNull);
      expect(problemWith('constants.dart', 'core'), isNull);
      expect(problemWith('package:flutter/material.dart', 'ui_shared'), isNull);
      expect(problemWith('package:fl_chart/fl_chart.dart', 'ui_shared'), isNull);
      expect(problemWith('../core/ledger.dart', 'ui_shared'), isNull);
      expect(
        problemWith('package:tu_expense_tracker/src/core/ledger.dart',
            'ui_shared'),
        isNull,
      );
    });

    test('every directive in a file is seen, not just the first', () {
      expect(
        importsOf('''
library;

import 'dart:convert';
import 'package:intl/intl.dart';
export 'constants.dart';

// import 'package:sqflite/sqflite.dart';
'''),
        <String>['dart:convert', 'package:intl/intl.dart', 'constants.dart'],
        reason: 'a commented-out directive is not an import',
      );
    });
  });
}
