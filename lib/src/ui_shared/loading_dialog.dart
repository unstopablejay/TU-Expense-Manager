/// Themed loading dialogs and visual indicators with an animated currency coin
/// and capsule progress bar.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// An animated 3D spinning currency coin with a floating bobbing effect.
class AnimatedCoin extends StatefulWidget {
  const AnimatedCoin({
    super.key,
    this.symbol = '₹',
    this.size = 56,
  });

  final String symbol;
  final double size;

  @override
  State<AnimatedCoin> createState() => _AnimatedCoinState();
}

class _AnimatedCoinState extends State<AnimatedCoin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double value = _controller.value;
        final double angle = value * 2 * math.pi;
        final double bob = math.sin(value * 2 * math.pi) * 4;

        // Front vs back face detection to keep symbol legible
        final bool isBackFace = (angle % (2 * math.pi)) > (math.pi / 2) &&
            (angle % (2 * math.pi)) < (3 * math.pi / 2);

        return Transform.translate(
          offset: Offset(0, bob),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0015) // perspective
              ..rotateY(angle),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    Color(0xFFFFE066),
                    Color(0xFFFFC72C),
                    Color(0xFFE59400),
                    Color(0xFFB87300),
                  ],
                  stops: <double>[0.0, 0.35, 0.7, 1.0],
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: const Color(0xFFE59400).withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
                border: Border.all(
                  color: const Color(0xFFFFF6CC),
                  width: 2.2,
                ),
              ),
              child: Center(
                child: Transform.scale(
                  scaleX: isBackFace ? -1 : 1,
                  child: Container(
                    width: widget.size * 0.72,
                    height: widget.size * 0.72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFFD68A00).withValues(alpha: 0.6),
                        width: 1.2,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        widget.symbol,
                        style: TextStyle(
                          fontSize: widget.size * 0.44,
                          fontWeight: FontWeight.w900,
                          color: const Color(0xFF523300),
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A capsule-shaped progress bar with an animated shimmering gradient sweep.
class CoinProgressBar extends StatefulWidget {
  const CoinProgressBar({
    super.key,
    this.height = 10,
    this.width = 200,
  });

  final double height;
  final double width;

  @override
  State<CoinProgressBar> createState() => _CoinProgressBarState();
}

class _CoinProgressBarState extends State<CoinProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) {
            return Container(
              color: isDark
                  ? theme.colorScheme.surfaceContainerHighest
                  : const Color(0xFFE8ECEF),
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: 0.45,
                      child: Transform.translate(
                        offset: Offset(
                          (_controller.value * 2.6 - 0.8) * widget.width,
                          0,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: <Color>[
                                theme.colorScheme.primary.withValues(alpha: 0.1),
                                theme.colorScheme.primary,
                                const Color(0xFFFFC72C),
                                theme.colorScheme.primary,
                                theme.colorScheme.primary.withValues(alpha: 0.1),
                              ],
                            ),
                            borderRadius:
                                BorderRadius.circular(widget.height / 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A Material 3 dialog featuring the animated coin and progress bar for modal
/// loading feedback during blocking operations.
class LoadingModal extends StatelessWidget {
  const LoadingModal({
    super.key,
    required this.message,
    this.subtitle,
    this.symbol = '₹',
  });

  final String message;
  final String? subtitle;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedCoin(symbol: symbol, size: 56),
          const SizedBox(height: 20),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 20),
          const CoinProgressBar(height: 8, width: 180),
        ],
      ),
    );
  }
}

/// Executes [task] while displaying a non-dismissible [LoadingModal].
///
/// Guaranteed to dismiss cleanly upon task completion or error.
Future<T> withLoadingModal<T>({
  required BuildContext context,
  required String message,
  String? subtitle,
  String symbol = '₹',
  required Future<T> Function() task,
}) async {
  if (!context.mounted) return await task();

  var dialogOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (BuildContext dialogContext) => PopScope(
      canPop: false,
      child: LoadingModal(
        message: message,
        subtitle: subtitle,
        symbol: symbol,
      ),
    ),
  ).then((_) {
    dialogOpen = false;
  });

  try {
    return await task();
  } finally {
    if (dialogOpen && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}

/// A scoped overlay widget that renders a subtle scrim and loading indicator
/// over [child] when [loading] is true.
class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({
    super.key,
    required this.child,
    required this.loading,
    this.message = 'Loading…',
    this.symbol = '₹',
  });

  final Widget child;
  final bool loading;
  final String message;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    if (!loading) return child;

    final theme = Theme.of(context);
    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(
          child: Container(
            color: theme.colorScheme.surface.withValues(alpha: 0.75),
            child: Center(
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 20,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AnimatedCoin(symbol: symbol, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        message,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const CoinProgressBar(height: 6, width: 140),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
