import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_music_player_dart/src/auth/login_service.dart';

void main() {
  test('normalizeCookieHeader keeps only auth cookies', () {
    final header = LoginService.normalizeCookieHeader(
      'SAPISID=abc; APISID=def; PREF=hl=pt; _ga=GA1.1.123; '
      'EMPTY=; JUNK; SID=ghi',
    );

    expect(header, isNotNull);
    expect(header, contains('SAPISID=abc'));
    expect(header, contains('APISID=def'));
    expect(header, contains('SID=ghi'));
    expect(header, isNot(contains('_ga=')));
    expect(header, isNot(contains('EMPTY=')));
  });

  test('normalizeCookieHeader rejects cookies without SAPISID', () {
    expect(LoginService.normalizeCookieHeader('PREF=hl=pt; YSC=xyz'), isNull);
  });

  test('parsePasted reads a Netscape cookies.txt file', () {
    const netscape = '# Netscape HTTP Cookie File\n'
        '.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tabc\n'
        '.youtube.com\tTRUE\t/\tTRUE\t0\tAPISID\tdef\n'
        '.example.com\tTRUE\t/\tTRUE\t0\tSAPISID\tmixed\n';

    final header = LoginService.parsePasted(netscape);

    expect(header, contains('SAPISID=abc'));
    expect(header, contains('APISID=def'));
    expect(header, isNot(contains('mixed')));
  });

  test('parsePasted reads an EditThisCookie JSON export', () {
    final json = jsonEncode([
      {'name': 'SAPISID', 'value': 'abc', 'domain': '.youtube.com'},
      {'name': 'APISID', 'value': 'def', 'domain': '.google.com'},
      {'name': '_ga', 'value': 'x', 'domain': '.youtube.com'},
    ]);

    final header = LoginService.parsePasted(json);

    expect(header, contains('SAPISID=abc'));
    expect(header, contains('APISID=def'));
    expect(header, isNot(contains('_ga=')));
  });

  test('firefoxRootPaths covers the XDG config location', () {
    final home = Platform.environment['HOME'];
    if (home == null) return;

    final roots = LoginService().firefoxRootPaths();

    expect(roots, contains('$home/.config/mozilla/firefox'));
    expect(roots, contains('$home/.mozilla/firefox'));
    expect(
      roots,
      contains('$home/.var/app/org.mozilla.firefox/config/mozilla/firefox'),
    );
  });
}
