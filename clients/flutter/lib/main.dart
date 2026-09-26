import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'src/design/theme.dart';
import 'src/kit_files.dart';
import 'src/onboarding.dart';
import 'src/profile_session.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  await ArveilRust.init();
  runApp(const ArveilApp());
}

class ArveilApp extends StatelessWidget {
  const ArveilApp({super.key, this.session, this.kitFiles = const KitFiles()});
  final ProfileSession? session;
  final KitFiles kitFiles;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Arveil',
    debugShowCheckedModeBanner: false,
    theme: ArveilTheme.light(),
    darkTheme: ArveilTheme.dark(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    localeListResolutionCallback: resolveLocale,
    builder: (context, child) {
      useStrings(context.l10n);
      return child!;
    },
    home: ProfilePage(session: session, kitFiles: kitFiles),
  );
}
