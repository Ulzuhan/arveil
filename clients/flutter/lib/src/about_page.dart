import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'design/design.dart';
import 'diagnostics.dart';
import 'links.dart';

/// "0.1.0-beta.3+21" as the packaging script sets it, shown as
/// "0.1.0-beta.3 (21)"; null in a local build.
String? displayVersion(String version) {
  if (version.isEmpty) return null;
  final [name, ...build] = version.split('+');
  return build.isEmpty ? name : '$name (${build.join('+')})';
}

/// Where Arveil lives on the web, in the reader's language.
abstract final class ArveilLinks {
  static final kaicorp = Uri.https('kaicorplabs.com', '/');
  static final source = Uri.https('github.com', '/Ulzuhan/arveil');
  static Uri website(AppLocalizations l10n) =>
      Uri.https('arveil.kaicorplabs.com', _spanish(l10n) ? '/es/' : '/');
  static Uri privacy(AppLocalizations l10n) => Uri.https(
    'arveil.kaicorplabs.com',
    _spanish(l10n) ? '/es/privacidad/' : '/privacy/',
  );
  static bool _spanish(AppLocalizations l10n) =>
      l10n.localeName.startsWith('es');
}

Future<void> openAbout(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const AboutArveilPage()));

/// Who makes Arveil, its privacy policy and source code, and the notices of
/// the libraries and typefaces it ships, which their licences require.
class AboutArveilPage extends StatelessWidget {
  const AboutArveilPage({
    super.key,
    this.open = openInBrowser,
    this.version = appVersion,
  });
  final OpenLink open;
  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = ArveilColors.of(context);
    final shown = displayVersion(version);
    final versionText = shown == null
        ? l10n.aboutLocalBuild
        : l10n.aboutVersion(shown);
    Widget link(
      String key,
      IconData icon,
      String title,
      Uri url, {
      String? subtitle,
    }) => SettingsRow(
      key: Key(key),
      icon: icon,
      title: title,
      subtitle: subtitle ?? '${url.host}${url.path == '/' ? '' : url.path}',
      external: true,
      onTap: () => followLink(context, url, open: open),
    );
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: EdgeInsets.symmetric(
                horizontal: WindowSize.of(context).margin + 8,
                vertical: 16,
              ),
              children: [
                Row(
                  children: [
                    const BrandMark(size: 56),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.appTitle,
                            style: ArveilType.screenTitle.copyWith(
                              color: c.ink,
                            ),
                          ),
                          Text(
                            versionText,
                            key: const Key('about-version'),
                            style: ArveilType.secondary.copyWith(
                              color: c.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.aboutBody,
                  style: ArveilType.preview.copyWith(color: c.ink),
                ),
                const SizedBox(height: 20),
                SettingsGroup(
                  children: [
                    link(
                      'about-kaicorp',
                      Icons.apartment_outlined,
                      l10n.aboutMadeBy,
                      ArveilLinks.kaicorp,
                    ),
                    link(
                      'about-website',
                      Icons.language,
                      l10n.aboutWebsite,
                      ArveilLinks.website(l10n),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SettingsGroup(
                  children: [
                    link(
                      'about-privacy',
                      Icons.privacy_tip_outlined,
                      l10n.privacyPolicy,
                      ArveilLinks.privacy(l10n),
                      subtitle: l10n.privacyPolicyHelp,
                    ),
                    link(
                      'about-source',
                      Icons.code,
                      l10n.aboutSource,
                      ArveilLinks.source,
                      subtitle: l10n.aboutSourceHelp,
                    ),
                    SettingsRow(
                      key: const Key('about-licenses'),
                      icon: Icons.description_outlined,
                      title: l10n.licenses,
                      subtitle: l10n.licensesHelp,
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: l10n.appTitle,
                        applicationVersion: versionText,
                        applicationIcon: const Padding(
                          padding: EdgeInsets.all(12),
                          child: BrandMark(size: 48),
                        ),
                        applicationLegalese: l10n.aboutLegalese,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  l10n.aboutLegalese,
                  key: const Key('about-legalese'),
                  textAlign: TextAlign.center,
                  style: ArveilType.secondary.copyWith(color: c.inkMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
