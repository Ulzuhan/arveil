import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'conversation_controller.dart';
import 'design/design.dart';
import 'rust/api/profile.dart';

/// Conversations started by people who are not contacts (ADR-012 §4): who
/// asks, which card they used if any, and the answer.
class RequestsSection extends StatelessWidget {
  const RequestsSection({super.key, required this.chat});
  final ConversationController chat;

  String _card(BuildContext context, RequestView request) {
    final l10n = context.l10n;
    return switch (request.card) {
      'link' when request.cardAt != null => l10n.requestUsedLink(
        MaterialLocalizations.of(context).formatMediumDate(
          DateTime.fromMillisecondsSinceEpoch(request.cardAt! * 1000),
        ),
      ),
      'in-person-pending' => l10n.requestChecking,
      'in-person' => l10n.requestInPerson,
      _ => l10n.requestNoLink,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        if (chat.requests.isEmpty) return const SizedBox.shrink();
        return Column(
          key: const Key('requests'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.requestsTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final row in chat.requests)
              if (row.request case final request?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SettingsGroup(
                    children: [
                      ListTile(
                        key: Key('request-${row.groupId}'),
                        leading: ArveilAvatar(
                          identity: request.from ?? row.groupId,
                          label: request.name ?? '',
                          size: 40,
                        ),
                        title: Text(
                          request.name != null
                              ? l10n.requestFromNamed(request.name!)
                              : l10n.requestFromUnnamed(
                                  (request.from ?? row.groupId).substring(0, 8),
                                ),
                        ),
                        subtitle: Text(_card(context, request)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            FilledButton.tonal(
                              key: Key('request-accept-${row.groupId}'),
                              onPressed: () =>
                                  chat.answerRequest(row.groupId, accept: true),
                              child: Text(l10n.requestAccept),
                            ),
                            OutlinedButton(
                              key: Key('request-decline-${row.groupId}'),
                              onPressed: () => chat.answerRequest(
                                row.groupId,
                                accept: false,
                              ),
                              child: Text(l10n.requestDecline),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        );
      },
    );
  }
}
