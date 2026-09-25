import 'package:flutter/material.dart';

import 'l10n/l10n.dart';
import 'src/appearance.dart';
import 'src/design/theme.dart';
import 'src/kit_files.dart';
import 'src/onboarding.dart';
import 'src/profile_session.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  await ArveilRust.init();
  final appearance = await AppearanceController.load(FileAppearanceStore());
  runApp(ArveilApp(appearance: appearance));
}

class ArveilApp extends StatefulWidget {
  const ArveilApp({
    super.key,
    this.session,
    this.kitFiles = const KitFiles(),
    this.appearance,
  });
  final ProfileSession? session;
  final KitFiles kitFiles;

  /// Defaults to one kept in memory, as in tests.
  final AppearanceController? appearance;

  @override
  State<ArveilApp> createState() => _ArveilAppState();
}

class _ArveilAppState extends State<ArveilApp> {
  late final AppearanceController _appearance =
      widget.appearance ?? AppearanceController(MemoryAppearanceStore());

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appearance,
    builder: (context, _) {
      final look = _appearance.value;
      return MaterialApp(
        onGenerateTitle: (context) => context.l10n.appTitle,
        debugShowCheckedModeBanner: false,
        theme: ArveilTheme.light(accent: look.accent),
        darkTheme: ArveilTheme.dark(accent: look.accent),
        themeMode: look.themeMode,
        locale: look.locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        localeListResolutionCallback: resolveLocale,
        builder: (context, child) {
          useStrings(context.l10n);
          final media = MediaQuery.of(context);
          return AppearanceScope(
            controller: _appearance,
            child: MediaQuery(
              data: media.copyWith(
                textScaler: TimesTextScaler(media.textScaler, look.textScale),
              ),
              child: child!,
            ),
          );
        },
        home: ProfilePage(session: widget.session, kitFiles: widget.kitFiles),
      );
    },
  );
}
