import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'design/design.dart';

enum ThemeChoice { system, light, dark }

enum LanguageChoice { system, spanish, english }

/// How the app looks on this device. Global and revealing nothing about
/// the profile: no conversation, name, route or image ever goes here, and
/// it is read before the profile opens because the welcome already uses
/// it.
@immutable
class Appearance {
  const Appearance({
    this.theme = ThemeChoice.system,
    this.accent = Accent.pine,
    this.wallpaper = Wallpaper.plain,
    this.textScale = 1.0,
    this.language = LanguageChoice.system,
  });
  final ThemeChoice theme;
  final Accent accent;
  final Wallpaper wallpaper;

  /// On top of the system's text size.
  final double textScale;
  final LanguageChoice language;

  static const textScales = [0.9, 1.0, 1.1, 1.2, 1.3];

  ThemeMode get themeMode => switch (theme) {
    ThemeChoice.system => ThemeMode.system,
    ThemeChoice.light => ThemeMode.light,
    ThemeChoice.dark => ThemeMode.dark,
  };

  /// Null follows the system.
  Locale? get locale => switch (language) {
    LanguageChoice.system => null,
    LanguageChoice.spanish => const Locale('es'),
    LanguageChoice.english => const Locale('en'),
  };

  Appearance copyWith({
    ThemeChoice? theme,
    Accent? accent,
    Wallpaper? wallpaper,
    double? textScale,
    LanguageChoice? language,
  }) => Appearance(
    theme: theme ?? this.theme,
    accent: accent ?? this.accent,
    wallpaper: wallpaper ?? this.wallpaper,
    textScale: textScale ?? this.textScale,
    language: language ?? this.language,
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'theme': theme.name,
    'accent': accent.name,
    'wallpaper': wallpaper.name,
    'textScale': textScale,
    'language': language.name,
  };

  /// Each field on its own: a missing or unknown one takes its default and
  /// leaves the others as they were.
  static Appearance fromJson(Object? json) {
    final map = json is Map ? json : const {};
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    final scale = map['textScale'];
    return Appearance(
      theme: pick(ThemeChoice.values, map['theme'], ThemeChoice.system),
      accent: pick(Accent.values, map['accent'], Accent.pine),
      wallpaper: pick(Wallpaper.values, map['wallpaper'], Wallpaper.plain),
      textScale: scale is num && textScales.contains(scale.toDouble())
          ? scale.toDouble()
          : 1.0,
      language: pick(
        LanguageChoice.values,
        map['language'],
        LanguageChoice.system,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.theme == theme &&
      other.accent == accent &&
      other.wallpaper == wallpaper &&
      other.textScale == textScale &&
      other.language == language;

  @override
  int get hashCode =>
      Object.hash(theme, accent, wallpaper, textScale, language);
}

/// Where the appearance is kept.
abstract interface class AppearanceStore {
  Future<String?> read();
  Future<void> write(String data);
}

/// A JSON file in the app's support directory, next to the profile and
/// never inside it. A write goes to a temporary file first and then
/// replaces the old one, so a crash leaves either version whole.
class FileAppearanceStore implements AppearanceStore {
  FileAppearanceStore([this._directory]);
  final Future<Directory> Function()? _directory;

  Future<File> _file() async {
    final directory = await (_directory ?? getApplicationSupportDirectory)();
    return File('${directory.path}/appearance.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> write(String data) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(data, flush: true);
    await temporary.rename(file.path);
  }
}

class MemoryAppearanceStore implements AppearanceStore {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String data) async => this.data = data;
}

/// The appearance in use. Changes apply at once and are saved in order;
/// a failed save keeps the change for this run.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._store, [this._value = const Appearance()]);
  final AppearanceStore _store;
  Appearance _value;
  Future<void> _saving = Future.value();

  Appearance get value => _value;

  /// The saved appearance, or the defaults when there is none or it
  /// cannot be read.
  static Future<AppearanceController> load(AppearanceStore store) async {
    try {
      final data = await store.read();
      final value = data == null
          ? const Appearance()
          : Appearance.fromJson(jsonDecode(data));
      return AppearanceController(store, value);
    } catch (_) {
      return AppearanceController(store);
    }
  }

  Future<void> update(Appearance next) {
    if (next == _value) return _saving;
    _value = next;
    notifyListeners();
    final data = jsonEncode(next.toJson());
    return _saving = _saving.then((_) async {
      try {
        await _store.write(data);
      } catch (_) {
        // Kept for this run; the next change tries again.
      }
    });
  }
}

/// Gives screens the appearance and a way to change it.
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}

/// The system's text scaling times the person's choice.
class TimesTextScaler extends TextScaler {
  const TimesTextScaler(this.base, this.factor);
  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is TimesTextScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
