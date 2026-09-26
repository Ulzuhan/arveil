import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'tokens.dart';
import 'typography.dart';

/// Initials of a local name on the identity's tone, or a person glyph when
/// the name is only a short identifier. Decorative: the name next to it is
/// what a screen reader announces.
class ArveilAvatar extends StatelessWidget {
  const ArveilAvatar({
    super.key,
    required this.identity,
    this.label,
    this.size = 48,
  });

  /// Stable identifier that chooses the tone, never a name that can change.
  final String identity;
  final String? label;
  final double size;

  /// Up to two initials, or none for a missing name or a short identifier.
  static String? initials(String? label) {
    final words = (label ?? '').trim().split(RegExp(r'\s+'));
    if (words.first.isEmpty || RegExp(r'^[0-9a-f]{8}$').hasMatch(words.first)) {
      return null;
    }
    return words
        .take(2)
        .map((w) => String.fromCharCode(w.runes.first).toUpperCase())
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final tone = ArveilColors.of(context).avatarFor(identity);
    final text = initials(label);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone.background,
          shape: BoxShape.circle,
        ),
        child: text == null
            ? Icon(
                Icons.person_outline,
                size: size * 0.5,
                color: tone.foreground,
              )
            : Text(
                text,
                style: ArveilType.rowName.copyWith(
                  fontSize: size * 0.36,
                  color: tone.foreground,
                ),
              ),
      ),
    );
  }
}

/// The shield next to a verified identity.
class VerifiedMark extends StatelessWidget {
  const VerifiedMark({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) => Icon(
    Icons.verified_user_outlined,
    size: size,
    color: ArveilColors.of(context).accent,
    semanticLabel: context.l10n.verified,
  );
}

/// An identity nobody compared a safety number with yet.
class UnverifiedChip extends StatelessWidget {
  const UnverifiedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.attention,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        context.l10n.unverified,
        style: ArveilType.label.copyWith(fontSize: 11.5, color: c.onAttention),
      ),
    );
  }
}

/// How many messages wait unread; announced in words.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Semantics(
      label: context.l10n.unreadMessages(count),
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minWidth: 22),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: ArveilType.label.copyWith(fontSize: 12, color: c.onAccent),
        ),
      ),
    );
  }
}

/// What Arveil can honestly say about a message this device sent. There
/// is no "read": the protocol does not carry it.
enum DeliveryStatus { none, pending, accepted, rejected, expired }

/// The status for the per-mailbox states Rust reports.
DeliveryStatus deliveryStatus(List<String> delivery) {
  if (delivery.isEmpty) return DeliveryStatus.none;
  if (delivery.any((s) => s.startsWith('undeliverable'))) {
    return DeliveryStatus.rejected;
  }
  if (delivery.any((s) => s == 'expired/unknown')) {
    return DeliveryStatus.expired;
  }
  if (delivery.every((s) => s.startsWith('accepted'))) {
    return DeliveryStatus.accepted;
  }
  return DeliveryStatus.pending;
}

/// One icon per status, with the words a screen reader says.
class DeliveryIcon extends StatelessWidget {
  const DeliveryIcon({
    super.key,
    required this.status,
    this.size = 15,
    this.color,
  });
  final DeliveryStatus status;
  final double size;

  /// The colour of the surrounding meta text, for pending and accepted.
  final Color? color;

  static String label(AppLocalizations l10n, DeliveryStatus status) =>
      switch (status) {
        DeliveryStatus.none => l10n.deliveryNone,
        DeliveryStatus.pending => l10n.deliveryWaiting,
        DeliveryStatus.accepted => l10n.deliveryAcceptedShort,
        DeliveryStatus.rejected => l10n.deliveryRejected,
        DeliveryStatus.expired => l10n.deliveryExpired,
      };

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final (icon, tint) = switch (status) {
      DeliveryStatus.pending => (Icons.schedule, color ?? c.inkMuted),
      DeliveryStatus.accepted => (Icons.check, color ?? c.inkMuted),
      DeliveryStatus.rejected => (Icons.error_outline, c.danger),
      DeliveryStatus.none ||
      DeliveryStatus.expired => (Icons.error_outline, c.onAttention),
    };
    return Icon(
      icon,
      size: size,
      color: tint,
      semanticLabel: label(context.l10n, status),
    );
  }
}

/// "Hoy", "Ayer" or a date between messages.
class DateSeparator extends StatelessWidget {
  const DateSeparator(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: ArveilShape.s2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: ArveilType.label.copyWith(color: c.inkMuted)),
      ),
    );
  }
}

/// A local notice inside a conversation, such as a device change.
class NoticeChip extends StatelessWidget {
  const NoticeChip({super.key, required this.text, this.detail, this.meta});
  final String text;
  final String? detail;
  final String? meta;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final small = ArveilType.secondary.copyWith(color: c.inkSoft);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        margin: const EdgeInsets.symmetric(vertical: ArveilShape.s2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(ArveilShape.buttonSmall),
        ),
        child: MergeSemantics(
          child: Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified_user_outlined, size: 16, color: c.accent),
                  const SizedBox(width: ArveilShape.s2),
                  Flexible(
                    child: Text(
                      text,
                      textAlign: TextAlign.center,
                      style: small,
                    ),
                  ),
                ],
              ),
              if (detail case final detail?)
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: ArveilType.meta.copyWith(color: c.inkMuted),
                ),
              if (meta case final meta?)
                Text(meta, style: ArveilType.meta.copyWith(color: c.inkMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

enum BannerTone { info, attention, error }

/// A notice at the top of a screen: offline, a kit to save, a failure.
/// Screen readers hear it when it appears.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.title,
    this.body,
    this.icon,
    this.tone = BannerTone.attention,
    this.actions = const [],
  });
  final String title;
  final String? body;
  final IconData? icon;
  final BannerTone tone;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final (background, foreground) = switch (tone) {
      BannerTone.info => (c.accentSoft, c.ink),
      BannerTone.attention => (c.attention, c.onAttention),
      BannerTone.error => (c.dangerSoft, c.onDangerSoft),
    };
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(ArveilShape.button),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon case final icon?) ...[
              Icon(icon, size: 22, color: foreground),
              const SizedBox(width: ArveilShape.s3),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: ArveilType.barTitle.copyWith(
                      fontSize: 15,
                      color: foreground,
                    ),
                  ),
                  if (body case final body?) ...[
                    const SizedBox(height: ArveilShape.s1),
                    Text(
                      body,
                      style: ArveilType.secondary.copyWith(
                        fontSize: 13.5,
                        height: 1.4,
                        color: foreground,
                      ),
                    ),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: ArveilShape.s2),
                    Wrap(spacing: ArveilShape.s2, children: actions),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line about synchronization with a coloured dot: reached, not
/// reached, or refused. It says when, never that anything was delivered.
class SyncLine extends StatelessWidget {
  const SyncLine({super.key, required this.text, required this.reached});
  final String text;

  /// Whether the last attempt reached the server; null while none ended.
  final bool? reached;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Row(
      children: [
        ExcludeSemantics(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: switch (reached) {
                true => c.online,
                false => c.onAttention,
                null => c.inkMuted,
              },
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: ArveilShape.s2),
        Expanded(
          child: Text(
            text,
            style: ArveilType.secondary.copyWith(color: c.inkMuted),
          ),
        ),
      ],
    );
  }
}

/// The safety number as eight groups of five digits in two columns, read
/// aloud group by group.
class SafetyNumberGrid extends StatelessWidget {
  const SafetyNumberGrid({super.key, required this.number, this.caption});
  final String number;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    final groups = number.trim().split(RegExp(r'\s+'));
    final style = ArveilType.safetyNumber.copyWith(color: c.ink);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.line),
        borderRadius: BorderRadius.circular(ArveilShape.card),
      ),
      child: Column(
        children: [
          Semantics(
            label: context.l10n.safetyNumberLabel(groups.join(', ')),
            excludeSemantics: true,
            child: Column(
              children: [
                for (var i = 0; i < groups.length; i += 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        for (final group in groups.skip(i).take(2))
                          Expanded(
                            child: Text(
                              group,
                              textAlign: TextAlign.center,
                              style: style,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (caption case final caption?) ...[
            const SizedBox(height: ArveilShape.s3),
            Text(
              caption,
              style: ArveilType.secondary.copyWith(color: c.inkMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a screen shows when it has nothing yet, and what to do about it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(ArveilShape.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: c.inkMuted),
            const SizedBox(height: ArveilShape.s4),
            Text(
              title,
              textAlign: TextAlign.center,
              style: ArveilType.barTitle.copyWith(color: c.ink),
            ),
            if (body case final body?) ...[
              const SizedBox(height: ArveilShape.s2),
              Text(
                body,
                textAlign: TextAlign.center,
                style: ArveilType.preview.copyWith(color: c.inkMuted),
              ),
            ],
            if (action case final action?) ...[
              const SizedBox(height: ArveilShape.s5),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

/// Settings rows grouped on one card, with inset dividers.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title case final title?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: ArveilType.label.copyWith(
                  fontSize: 13,
                  color: c.inkMuted,
                ),
              ),
            ),
          ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(ArveilShape.card),
          ),
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) Divider(height: 1, indent: 66, color: c.divider),
                child,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One setting: an icon tile, a title, what it is now, and where it leads.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.value,
    this.attention = false,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;

  /// A short current value shown at the end, such as "Automática".
  final String? value;

  /// Draws the row as something that needs the user, such as a kit to save.
  final bool attention;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 60),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: attention ? c.attention : c.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: attention ? c.onAttention : c.accent,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ArveilType.preview.copyWith(
                        fontSize: 15.5,
                        color: c.ink,
                        fontWeight: FontWeight.w500,
                        fontVariations: const [FontVariation.weight(500)],
                      ),
                    ),
                    if (subtitle case final subtitle?)
                      Text(
                        subtitle,
                        style: ArveilType.secondary.copyWith(
                          color: attention ? c.onAttention : c.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              if (value case final value?)
                Text(
                  value,
                  style: ArveilType.preview.copyWith(
                    fontSize: 14,
                    color: c.inkMuted,
                  ),
                ),
              if (onTap != null && value == null)
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, size: 20, color: c.inkMuted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
