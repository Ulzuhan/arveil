import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'l10n/l10n.dart';
import 'src/appearance.dart';
import 'src/design/theme.dart';
import 'src/kit_files.dart';
import 'src/onboarding.dart';
import 'src/profile_session.dart';
import 'src/rust/frb_generated.dart';
import 'src/updates/controller.dart';
import 'src/updates/manifest.dart';
import 'src/updates/page.dart';
import 'src/rust/api/updates.dart' show verifyUpdateSignature;
import 'src/updates/transport.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  await ArveilRust.init();
  final appearance = await AppearanceController.load(FileAppearanceStore());
  UpdateController? updates;
  if (Platform.isAndroid) {
    updates = UpdateController(
      config: UpdateConfig.fromEnvironment(),
      store: FileUpdateStore(await getApplicationSupportDirectory()),
      transport: HttpsUpdateTransport(
        () async =>
            Directory('${(await getTemporaryDirectory()).path}/updates'),
      ),
      installer: AndroidUpdateInstaller(),
      verifier: (payload, signature, publicKey) => verifyUpdateSignature(
        payload: payload,
        signature: signature,
        publicKey: publicKey,
      ),
    );
    await updates.load();
  }
  runApp(ArveilApp(appearance: appearance, updates: updates));
}

class ArveilApp extends StatefulWidget {
  const ArveilApp({
    super.key,
    this.session,
    this.kitFiles = const KitFiles(),
    this.appearance,
    this.updates,
  });
  final ProfileSession? session;
  final KitFiles kitFiles;

  /// Defaults to one kept in memory, as in tests.
  final AppearanceController? appearance;
  final UpdateController? updates;

  @override
  State<ArveilApp> createState() => _ArveilAppState();
}

class _ArveilAppState extends State<ArveilApp> {
  final _navigator = GlobalKey<NavigatorState>();
  late final AppearanceController _appearance =
      widget.appearance ?? AppearanceController(MemoryAppearanceStore());

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appearance,
    builder: (context, _) {
      final look = _appearance.value;
      return MaterialApp(
        navigatorKey: _navigator,
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
              child: widget.updates == null
                  ? child!
                  : UpdateScope(
                      controller: widget.updates!,
                      child: UpdateLifecycle(
                        controller: widget.updates!,
                        navigator: _navigator,
                        child: child!,
                      ),
                    ),
            ),
          );
        },
        home: ProfilePage(session: widget.session, kitFiles: widget.kitFiles),
      );
    },
  );
}
