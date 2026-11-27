import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Cookie names that authenticate a Google/YouTube session.
///
/// Keeping only these avoids sending analytics/consent cookies (and keeps the
/// `Cookie` header comfortably under server limits).
const _authCookieNames = <String>{
  'SAPISID',
  '__Secure-3PAPISID',
  '__Secure-1PAPISID',
  'SID',
  'HSID',
  'SSID',
  'APISID',
  '__Secure-1PSID',
  '__Secure-3PSID',
  'LOGIN_INFO',
  'SIDCC',
  '__Secure-1PSIDTS',
  '__Secure-3PSIDTS',
  'VISITOR_INFO1_LIVE',
  'VISITOR_PRIVACY_METADATA',
  'PREF',
  'CONSENT',
  'SOCS',
  'YSC',
  'NID',
  'AEC',
};

class CookieEntry {
  const CookieEntry({required this.name, required this.value});

  final String name;
  final String value;
}

/// Outcome of importing a session from a local Firefox profile.
class FirefoxImportResult {
  const FirefoxImportResult._({
    this.cookies,
    this.profilePath,
    this.searchedRoots = const [],
    this.profilesChecked = 0,
  });

  factory FirefoxImportResult.found(String cookies, String profilePath) =>
      FirefoxImportResult._(cookies: cookies, profilePath: profilePath);

  factory FirefoxImportResult.notFound(List<String> searchedRoots) =>
      FirefoxImportResult._(searchedRoots: searchedRoots);

  factory FirefoxImportResult.noSession(
    int profilesChecked,
    List<String> searchedRoots,
  ) =>
      FirefoxImportResult._(
        profilesChecked: profilesChecked,
        searchedRoots: searchedRoots,
      );

  /// Normalized `Cookie:` header when the import succeeded.
  final String? cookies;

  /// Path of the profile database the cookies came from.
  final String? profilePath;

  /// Firefox roots that exist on this machine.
  final List<String> searchedRoots;

  /// Number of `cookies.sqlite` files inspected.
  final int profilesChecked;

  bool get found => cookies != null;
}

/// Extracts/normalizes a Google session from several sources.
class LoginService {
  /// Normalizes a raw `Cookie:` header.
  ///
  /// Accepts the exact header copied from DevTools and ignores anything that is
  /// not part of the authenticated Google/YouTube session.
  static String? normalizeCookieHeader(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isEmpty) return null;
    final entries = <String, String>{};
    for (final part in cleaned.split(';')) {
      final trimmed = part.trim();
      final index = trimmed.indexOf('=');
      if (index <= 0) continue;
      final name = trimmed.substring(0, index).trim();
      final value = trimmed.substring(index + 1).trim();
      if (!_authCookieNames.contains(name)) continue;
      if (value.isEmpty) continue;
      if (name == 'SAPISID' || name.endsWith('PAPISID')) {
        entries[name] = value;
      } else {
        entries.putIfAbsent(name, () => value);
      }
    }
    if (!entries.containsKey('SAPISID') &&
        !entries.containsKey('__Secure-3PAPISID') &&
        !entries.containsKey('__Secure-1PAPISID')) {
      return null;
    }
    return entries.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Parses several common formats:
  ///  - `name=value; name=value` (DevTools header)
  ///  - Netscape `cookies.txt` (Get cookies.txt extension / yt-dlp)
  ///  - JSON array of `{name, value, domain}` (EditThisCookie style)
  static String? parsePasted(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    if (text.startsWith('[')) {
      try {
        final list = jsonDecode(text);
        if (list is List) {
          final pairs = <String>[];
          for (final entry in list) {
            if (entry is! Map) continue;
            final name = entry['name']?.toString();
            final value = entry['value']?.toString();
            final domain = entry['domain']?.toString() ?? '';
            if (name == null || value == null) continue;
            if (!_authCookieNames.contains(name)) continue;
            if (domain.isNotEmpty &&
                !domain.contains('youtube.com') &&
                !domain.contains('google.com')) {
              continue;
            }
            pairs.add('$name=$value');
          }
          if (pairs.isNotEmpty) return normalizeCookieHeader(pairs.join('; '));
        }
      } catch (_) {}
    }

    if (text.contains('\t')) {
      final pairs = <String>[];
      for (final line in const LineSplitter().convert(text)) {
        if (line.startsWith('#') || line.trim().isEmpty) continue;
        final columns = line.split('\t');
        if (columns.length < 7) continue;
        final domain = columns[0];
        if (!domain.contains('youtube.com') && !domain.contains('google.com')) {
          continue;
        }
        final name = columns[5];
        final value = columns[6];
        if (!_authCookieNames.contains(name) || value.isEmpty) continue;
        pairs.add('$name=$value');
      }
      if (pairs.isNotEmpty) return normalizeCookieHeader(pairs.join('; '));
    }

    return normalizeCookieHeader(text);
  }

  /// Locations where Firefox keeps its profiles on Linux.
  ///
  /// Besides the classic `~/.mozilla/firefox`, some setups (custom
  /// `HOME`/`XDG_CONFIG_HOME`, distro patching, Firefox Developer Edition)
  /// store profiles under `~/.config/mozilla/firefox`.
  List<String> firefoxRootPaths() {
    final home = Platform.environment['HOME'];
    final configHome = Platform.environment['XDG_CONFIG_HOME'];
    final paths = <String>{
      if (home != null) ...[
        '$home/.mozilla/firefox',
        '$home/.config/mozilla/firefox',
        '$home/.local/share/mozilla/firefox',
        '$home/snap/firefox/common/.mozilla/firefox',
        '$home/.var/app/org.mozilla.firefox/.mozilla/firefox',
        '$home/.var/app/org.mozilla.firefox/config/mozilla/firefox',
        '$home/.var/app/org.mozilla.firefox/.mozilla/firefox',
      ],
      if (configHome != null) '$configHome/mozilla/firefox',
    };
    return paths.toList();
  }

  /// Imports cookies from a local Firefox profile (Linux).
  ///
  /// Firefox stores cookies unencrypted in `cookies.sqlite`, unlike Chromium,
  /// which encrypts them with the OS keyring.
  Future<FirefoxImportResult> importFromFirefox() async {
    final dbFiles = <File>[];
    final searched = <String>[];
    for (final path in firefoxRootPaths()) {
      final root = Directory(path);
      if (!await root.exists()) continue;
      searched.add(path);
      try {
        await for (final entity
            in root.list(recursive: true, followLinks: false)) {
          if (entity is File &&
              (entity.path.endsWith('cookies.sqlite') ||
                  entity.path.endsWith('cookies.sqlite-wal'))) {
            dbFiles.add(entity);
          }
        }
      } catch (_) {
        // Permission problems: keep looking in the other roots.
      }
    }

    // Only the main database file is opened; WAL/SHM are copied along with it.
    final databases = dbFiles
        .where((file) => file.path.endsWith('cookies.sqlite'))
        .toList();
    if (databases.isEmpty) {
      return FirefoxImportResult.notFound(searched);
    }

    // Most recently modified profile first (the one the user actually uses).
    final filesWithStat = <MapEntry<File, DateTime>>[];
    for (final file in databases) {
      try {
        filesWithStat.add(MapEntry(file, (await file.stat()).modified));
      } catch (_) {}
    }
    filesWithStat.sort((a, b) => b.value.compareTo(a.value));

    final tempDir = await _tempDirectory();
    for (final entry in filesWithStat) {
      Database? db;
      File? copy;
      try {
        copy = File(
          '${tempDir.path}/cookies_${DateTime.now().microsecondsSinceEpoch}.sqlite',
        );
        await entry.key.copy(copy.path);
        // Recent cookies live in the WAL, so copy it too. The copy is opened
        // read-write so SQLite can replay the WAL; the original stays untouched.
        for (final suffix in const ['-wal', '-shm']) {
          final sidecar = File('${entry.key.path}$suffix');
          if (await sidecar.exists()) {
            try {
              await sidecar.copy('${copy.path}$suffix');
            } catch (_) {}
          }
        }
        db = sqlite3.open(copy.path);
        final nowSeconds =
            DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
        // Firefox versions disagree on the unit of `expiry` (seconds or
        // milliseconds), so accept either.
        final rows = db.select(
          "SELECT name, value FROM moz_cookies "
          "WHERE (host LIKE '%youtube.com' OR host LIKE '%google.com') "
          "AND (expiry = 0 OR expiry > ? OR expiry > ?) "
          "ORDER BY CASE WHEN host LIKE '%.youtube.com' THEN 0 ELSE 1 END",
          [nowSeconds, nowSeconds * 1000],
        );
        final pairs = <String>[];
        for (final row in rows) {
          final name = row['name']?.toString() ?? '';
          final value = row['value']?.toString() ?? '';
          if (!_authCookieNames.contains(name) || value.isEmpty) continue;
          pairs.add('$name=$value');
        }
        final header = normalizeCookieHeader(pairs.join('; '));
        if (header != null) {
          return FirefoxImportResult.found(header, entry.key.path);
        }
      } catch (_) {
        // Try the next profile.
      } finally {
        db?.dispose();
        if (copy != null) {
          for (final suffix in const ['', '-wal', '-shm']) {
            try {
              final file = File('${copy.path}$suffix');
              if (await file.exists()) await file.delete();
            } catch (_) {}
          }
        }
      }
    }
    return FirefoxImportResult.noSession(filesWithStat.length, searched);
  }

  Future<Directory> _tempDirectory() async {
    try {
      return await getTemporaryDirectory();
    } catch (_) {
      // path_provider is unavailable in unit tests and on some hosts.
      return Directory.systemTemp;
    }
  }

  /// True when the current platform can auto-import from a local browser.
  bool get canImportFromBrowser =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS);

  /// Opens music.youtube.com in the default browser.
  Future<bool> openLoginInBrowser() async {
    if (kIsWeb) return false;
    const url = 'https://music.youtube.com/';
    try {
      late final ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('cmd', ['/c', 'start', '', url]);
      } else {
        result = await Process.run(
          Platform.isLinux ? 'xdg-open' : 'open',
          [url],
        );
      }
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// User-Agent for the embedded login browser.
  ///
  /// Google is picky about WebViews, so we impersonate a normal browser:
  /// Chrome/Edge on Windows and Chrome Mobile on Android. The desktop UA also
  /// keeps the YouTube Music channel switcher identical to the site.
  static String embeddedBrowserUserAgent({bool? windows}) {
    final isWindows = windows ?? (!kIsWeb && Platform.isWindows);
    if (isWindows) {
      return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0';
    }
    return 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
  }

  /// Platforms where the embedded Google login browser is available.
  ///
  /// Windows uses the WebView2 runtime shipped with Edge; Android uses the
  /// system WebView. On Linux/macOS the app falls back to cookie import.
  static bool supportsEmbeddedBrowser(String operatingSystem) =>
      operatingSystem == 'android' || operatingSystem == 'windows';

  bool get canUseEmbeddedBrowser =>
      !kIsWeb && supportsEmbeddedBrowser(Platform.operatingSystem);
}
