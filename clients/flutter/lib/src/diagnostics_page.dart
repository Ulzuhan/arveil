import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'diagnostics.dart';
import 'profile_session.dart';

/// Shows the diagnostic report before anything leaves the device, and
/// saves it through the native dialog when asked.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({
    super.key,
    required this.session,
    this.files = const DiagnosticFiles(),
  });
  final ProfileSession session;
  final DiagnosticFiles files;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late final Future<String> _report = diagnosticReport(widget.session);
  bool _saving = false;

  Future<void> _save(String report) async {
    setState(() => _saving = true);
    final l10n = context.l10n;
    try {
      final saved = await widget.files.save(report);
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.diagnosticsSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.diagnosticsSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.diagnosticsTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: FutureBuilder<String>(
              future: _report,
              builder: (context, snapshot) {
                final report = snapshot.data;
                return ListView(
                  padding: EdgeInsets.symmetric(
                    horizontal: WindowSize.of(context).margin + 8,
                    vertical: 16,
                  ),
                  children: [
                    Text(l10n.diagnosticsExplanation),
                    const SizedBox(height: 12),
                    StatusBanner(
                      title: l10n.diagnosticsPrivacyTitle,
                      body: l10n.diagnosticsPrivacyBody,
                      icon: Icons.privacy_tip_outlined,
                      tone: BannerTone.info,
                    ),
                    const SizedBox(height: 16),
                    if (report == null)
                      const Center(child: CircularProgressIndicator())
                    else ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: c.surface,
                          border: Border.all(color: c.line),
                          borderRadius: BorderRadius.circular(
                            ArveilShape.buttonSmall,
                          ),
                        ),
                        child: SelectableText(
                          report,
                          key: const Key('diagnostic-report'),
                          style: ArveilType.identifier.copyWith(color: c.ink),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('save-diagnostics'),
                        onPressed: _saving ? null : () => _save(report),
                        icon: const Icon(Icons.save_alt),
                        label: Text(l10n.diagnosticsSave),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
