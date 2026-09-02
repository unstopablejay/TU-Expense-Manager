/// A custom floating "undo" toast that sits above the bottom navigation bar.
///
/// Replaces Flutter's built-in [SnackBar] for delete / merge operations with
/// a richer card:
///   - **Scale + fade** pop-in and shrink-out animation.
///   - **Shrinking progress bar** at the bottom that depletes over 10 seconds,
///     giving the user a visual countdown before auto-dismiss.
///   - **X close button** for instant manual dismissal.
///   - **Undo action button** that fires a callback and then dismisses.
///   - **Queue**: when a second toast is shown while one is still visible, the
///     first is dismissed and the second is shown once the animation completes.
///
/// Usage
/// -----
/// Obtain an [UndoToastController] from [UndoToast.controllerOf] and call
/// [UndoToastController.show]:
/// ```dart
/// UndoToast.controllerOf(context).show(
///   message: 'Deleted Swiggy',
///   onUndo: () async { /* restore */ },
/// );
/// ```
///
/// Wrap your scaffold body (or the whole screen) with [UndoToast]:
/// ```dart
/// UndoToast(child: Scaffold(...))
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Drives an [UndoToast] from anywhere below it in the widget tree.
class UndoToastController extends ChangeNotifier {
  _UndoToastEntry? _pending;
  _UndoToastEntry? _active;

  /// True when a toast is currently displayed (or animating in/out).
  bool get hasActive => _active != null;

  /// The currently displayed entry, exposed for tests via the internal getter.
  // ignore: library_private_types_in_public_api
  _UndoToastEntry? get active => _active;

  void show({required String message, required Future<void> Function() onUndo}) {
    final entry = _UndoToastEntry(message: message, onUndo: onUndo);
    if (_active == null) {
      _active = entry;
      notifyListeners();
    } else {
      // Queue: dismiss current, then show new.
      _pending = entry;
      dismissActive();
    }
  }

  /// Dismisses the currently visible toast. If an entry was queued, it becomes
  /// active immediately (the animation widget handles deferred queuing; in unit
  /// tests where there is no widget, promotion is synchronous).
  void dismissActive() {
    if (_active == null) return;
    final cb = _active?.dismiss;
    if (cb != null) {
      // Widget is mounted — let the animation complete, then _onHidden fires.
      cb();
    } else {
      // No widget (unit tests) — promote immediately.
      _active = _pending;
      _pending = null;
      notifyListeners();
    }
  }

  /// Called by the toast widget when its animation fully completes (hidden).
  void _onHidden() {
    _active = _pending;
    _pending = null;
    notifyListeners();
  }
}

class _UndoToastEntry {
  _UndoToastEntry({required this.message, required this.onUndo});

  final String message;
  final Future<void> Function() onUndo;

  /// Set by [_UndoToastState] once it has mounted. Calling it starts dismiss.
  VoidCallback? dismiss;
}

// ---------------------------------------------------------------------------
// Public widget
// ---------------------------------------------------------------------------

/// Wraps [child] and draws an animated undo-toast card floating above the
/// bottom of the widget when an action is triggered via [controllerOf].
class UndoToast extends StatefulWidget {
  const UndoToast({super.key, required this.child});

  final Widget child;

  /// Returns the nearest [UndoToastController] in the tree.
  static UndoToastController controllerOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_UndoToastScope>();
    assert(scope != null,
        'No UndoToast found in the widget tree. Wrap a widget with UndoToast(...).');
    return scope!.controller;
  }

  @override
  State<UndoToast> createState() => _UndoToastState();
}

class _UndoToastState extends State<UndoToast> {
  final UndoToastController _controller = UndoToastController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_rebuild);
  }

  @override
  void dispose() {
    _controller.removeListener(_rebuild);
    _controller.dispose();
    super.dispose();
  }

  void _rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return _UndoToastScope(
      controller: _controller,
      child: Stack(
        children: <Widget>[
          widget.child,
          if (_controller._active != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _UndoToastCard(
                key: ValueKey<_UndoToastEntry>(_controller._active!),
                entry: _controller._active!,
                controller: _controller,
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inherited scope
// ---------------------------------------------------------------------------

class _UndoToastScope extends InheritedWidget {
  const _UndoToastScope({
    required this.controller,
    required super.child,
  });

  final UndoToastController controller;

  @override
  bool updateShouldNotify(_UndoToastScope old) => controller != old.controller;
}

// ---------------------------------------------------------------------------
// The animated card
// ---------------------------------------------------------------------------

/// Duration of the scale+fade pop-in / shrink-out animation.
const Duration _kAnimDuration = Duration(milliseconds: 220);

/// How long the toast stays fully visible before auto-dismissing.
const Duration _kAutoDismiss = Duration(seconds: 10);

class _UndoToastCard extends StatefulWidget {
  const _UndoToastCard({
    super.key,
    required this.entry,
    required this.controller,
  });

  final _UndoToastEntry entry;
  final UndoToastController controller;

  @override
  State<_UndoToastCard> createState() => _UndoToastCardState();
}

class _UndoToastCardState extends State<_UndoToastCard>
    with TickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _kAnimDuration,
  );

  late final Animation<double> _scale =
      CurvedAnimation(parent: _anim, curve: Curves.easeOutBack);
  late final Animation<double> _fade =
      CurvedAnimation(parent: _anim, curve: Curves.easeOut);

  /// Progress bar animation — goes from 1.0 to 0.0 over [_kAutoDismiss].
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: _kAutoDismiss,
    value: 1.0,
  );

  Timer? _autoTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    // Register dismiss callback on the entry.
    widget.entry.dismiss = _dismiss;

    // Pop in.
    _anim.forward();

    // Start shrinking the progress bar and schedule auto-dismiss.
    _progress.reverse();
    _autoTimer = Timer(_kAutoDismiss, _dismiss);
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _anim.dispose();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _autoTimer?.cancel();
    _progress.stop();
    await _anim.reverse();
    if (mounted) {
      widget.controller._onHidden();
    }
  }

  Future<void> _onUndo() async {
    _autoTimer?.cancel();
    await widget.entry.onUndo();
    await _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Use the inverse surface colours so it pops against both light and dark.
    final bgColor = colorScheme.inverseSurface;
    final fgColor = colorScheme.onInverseSurface;
    final accentColor = colorScheme.inversePrimary;

    return FadeTransition(
      opacity: _fade,
      child: ScaleTransition(
        scale: _scale,
        alignment: Alignment.bottomCenter,
        child: Padding(
          // Sits 8 dp above the bottom nav bar and has 12 dp side margins.
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Material(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            elevation: 6,
            shadowColor: Colors.black38,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: <Widget>[
                      // Message
                      Expanded(
                        child: Text(
                          widget.entry.message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: fgColor,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Undo button
                      TextButton(
                        onPressed: _onUndo,
                        style: TextButton.styleFrom(
                          foregroundColor: accentColor,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Undo',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      // X close button
                      IconButton(
                        onPressed: _dismiss,
                        icon: Icon(Icons.close, color: fgColor, size: 18),
                        padding: const EdgeInsets.all(6),
                        constraints: const BoxConstraints(),
                        tooltip: 'Dismiss',
                      ),
                    ],
                  ),
                ),
                // Shrinking progress line at the bottom of the card.
                AnimatedBuilder(
                  animation: _progress,
                  builder: (BuildContext context, Widget? _) {
                    return ClipRRect(
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                      child: LinearProgressIndicator(
                        value: _progress.value,
                        minHeight: 3,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
