import 'package:flutter/widgets.dart';

/// The client plan's window sizes (docs/es/CLIENT_DESIGN.md, "Pantallas y
/// navegación"): compact below 600 dp, medium up to 839 and expanded from
/// 840, where the chat list and the conversation share the window.
enum WindowSize {
  compact,
  medium,
  expanded;

  static const mediumFrom = 600.0;
  static const expandedFrom = 840.0;

  /// From this width a conversation's details can stay open beside it.
  static const detailsFrom = 1200.0;

  static WindowSize forWidth(double width) => width >= expandedFrom
      ? expanded
      : width >= mediumFrom
      ? medium
      : compact;

  static WindowSize of(BuildContext context) =>
      forWidth(MediaQuery.sizeOf(context).width);

  /// List and conversation side by side, with a navigation rail.
  bool get twoPane => this == expanded;

  /// Side margin of single-column content: medium windows get more room.
  double get margin => this == medium ? 32 : 16;
}
