import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AudioQuality {
  low('Baixa (economia de dados)'),
  normal('Normal'),
  high('Alta');

  const AudioQuality(this.label);

  final String label;
}

/// User preferences. Also read by the playback isolate through a plain
/// snapshot passed by the UI (never by touching plugins from the isolate).
class SettingsStore extends ChangeNotifier {
  static const _kSkipAds = 'skip_ads';
  static const _kSkipIntros = 'skip_intros';
  static const _kSponsor = 'skip_sponsor';
  static const _kFixedIntro = 'fixed_intro_seconds';
  static const _kAutoplay = 'autoplay';
  static const _kQuality = 'audio_quality';
  static const _kLanguage = 'language';
  static const _kRegion = 'region';
  static const _kSkipCategories = 'skip_categories';

  SharedPreferences? _prefs;

  bool skipAds = true;
  bool skipIntros = true;
  bool skipSponsor = true;
  int fixedIntroSeconds = 0;
  bool autoplay = true;
  AudioQuality quality = AudioQuality.high;
  String language = 'pt';
  String region = 'BR';
  Set<String> sponsorCategories = {'intro', 'sponsor', 'selfpromo'};

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    skipAds = p.getBool(_kSkipAds) ?? true;
    skipIntros = p.getBool(_kSkipIntros) ?? true;
    skipSponsor = p.getBool(_kSponsor) ?? true;
    fixedIntroSeconds = p.getInt(_kFixedIntro) ?? 0;
    autoplay = p.getBool(_kAutoplay) ?? true;
    quality = AudioQuality.values.firstWhere(
      (q) => q.name == p.getString(_kQuality),
      orElse: () => AudioQuality.high,
    );
    language = p.getString(_kLanguage) ?? 'pt';
    region = p.getString(_kRegion) ?? 'BR';
    final categories = p.getStringList(_kSkipCategories);
    if (categories != null) sponsorCategories = categories.toSet();
    notifyListeners();
  }

  Future<void> update(void Function(SettingsStore s) change) async {
    change(this);
    notifyListeners();
    final p = _prefs;
    if (p == null) return;
    await Future.wait([
      p.setBool(_kSkipAds, skipAds),
      p.setBool(_kSkipIntros, skipIntros),
      p.setBool(_kSponsor, skipSponsor),
      p.setInt(_kFixedIntro, fixedIntroSeconds),
      p.setBool(_kAutoplay, autoplay),
      p.setString(_kQuality, quality.name),
      p.setString(_kLanguage, language),
      p.setString(_kRegion, region),
      p.setStringList(_kSkipCategories, sponsorCategories.toList()),
    ]);
  }
}
