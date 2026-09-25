import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'profile_session.dart';
import 'rust/api/profile.dart';

class KeyPackagesPanel extends StatelessWidget {
  const KeyPackagesPanel({super.key, required this.session});
  final ProfileSession session;

  @override
  Widget build(BuildContext context) {
    final supply = session.keyPackages;
    final level = supply?.level ?? KeyPackageLevelView.unknown;
    final pending = supply?.publicationPending ?? false;
    final canReplenish =
        pending ||
        level == KeyPackageLevelView.empty ||
        level == KeyPackageLevelView.low;
    final checked = supply?.checkedAt;
    final date = checked == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(checked.toInt() * 1000);
    return Column(
      key: const Key('key-package-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.l10n.keyPackagesTitle,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        Text(context.l10n.keyPackagesExplanation),
        const SizedBox(height: 12),
        Text(
          switch (level) {
            KeyPackageLevelView.unknown => context.l10n.keyPackagesUnknown,
            KeyPackageLevelView.empty => context.l10n.keyPackagesEmpty,
            KeyPackageLevelView.low => context.l10n.keyPackagesLow,
            KeyPackageLevelView.ready => context.l10n.keyPackagesReady,
          },
          key: const Key('key-package-state'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (supply?.available case final count?) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.keyPackagesCount(count),
            key: const Key('key-package-count'),
          ),
        ],
        if (date != null) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.keyPackagesCheckedAt(
              numericDate(context.l10n, date),
              clockTime(date),
            ),
          ),
        ],
        if (level == KeyPackageLevelView.empty) ...[
          const SizedBox(height: 8),
          Text(context.l10n.keyPackagesNoneWarning),
        ],
        if (level == KeyPackageLevelView.low) ...[
          const SizedBox(height: 8),
          Text(context.l10n.keyPackagesReplenishSoon),
        ],
        if (pending) ...[
          const SizedBox(height: 8),
          Text(context.l10n.keyPackagesPending),
        ],
        if (session.keyPackagesUnavailable) ...[
          const SizedBox(height: 8),
          Text(
            context.l10n.keyPackagesUnavailable,
            key: Key('key-package-unavailable'),
          ),
        ],
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: session.busy ? null : () => session.checkKeyPackages(),
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.keyPackagesCheck),
        ),
        if (canReplenish) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: session.busy
                ? null
                : () => session.checkKeyPackages(replenish: true),
            child: Text(
              pending
                  ? context.l10n.keyPackagesResume
                  : context.l10n.keyPackagesReplenish,
            ),
          ),
        ],
      ],
    );
  }
}
