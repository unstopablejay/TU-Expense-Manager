/// The connection light, in the corner of both app bars.
///
/// One widget for the phone and the browser, for the same reason the rule behind
/// it is one function: two lights that mean slightly different things by green
/// would be worse than no light at all.
///
/// Green is solid and red is a ring rather than only a change of colour. Roughly
/// one man in twelve cannot tell the two hues apart, and a status light that
/// carries its whole meaning in a hue is a status light he cannot read. The
/// tooltip carries the detail, and the semantics label carries it to a screen
/// reader.
library;

import 'package:flutter/material.dart';

import '../core/link_state.dart';

/// Green, and red, in shades that hold up on both a light and a dark surface.
///
/// Not from the chart palette: those eight are chosen to be told apart from each
/// other, which is a different job from being unmistakably "good" and "bad".
const Color _greenLight = Color(0xFF1E8E3E);
const Color _greenDark = Color(0xFF5BB974);
const Color _redLight = Color(0xFFC5221F);
const Color _redDark = Color(0xFFF28B82);

/// A dot saying whether this device and the server are in touch.
class ConnectionDot extends StatelessWidget {
  const ConnectionDot({
    required this.state,
    required this.tooltip,
    this.onTap,
    super.key,
  });

  final LinkState state;

  /// The sentence behind the colour — which server, when it was last heard from,
  /// what went wrong. The dot is the summary; this is the answer.
  final String tooltip;

  /// What tapping it does, where there is something useful to do — on the phone,
  /// check again now rather than at the next interval.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color color = switch (state) {
      LinkState.connected => dark ? _greenDark : _greenLight,
      LinkState.disconnected => dark ? _redDark : _redLight,
      LinkState.unknown => Theme.of(context).disabledColor,
    };

    return Semantics(
      label: switch (state) {
        LinkState.connected => 'Connected to the server. $tooltip',
        LinkState.disconnected => 'Not connected to the server. $tooltip',
        LinkState.unknown => 'Server sync is not set up. $tooltip',
      },
      // The dot itself says everything twice over, so the tree underneath it is
      // noise to a screen reader.
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: Padding(
            // Enough that the tap target is a reasonable size without the dot
            // looking like it is trying to be a button.
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // Solid when connected, a ring when not: the shape is what makes
                // this readable without the colour.
                color: state == LinkState.connected ? color : Colors.transparent,
                border: Border.all(color: color, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
