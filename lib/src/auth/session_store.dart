import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/models.dart';

/// Persists the Google session (cookies) captured from the login flow.
///
/// The file lives in the application support directory, which is private to
/// the app on Android. On Linux we also tighten the permissions to 0600.
class SessionStore extends ChangeNotifier {
  SessionStore();

  static const _fileName = 'ytmusic_session.json';

  String? _cookies;
  String? _visitorData;
  String? _brandAccountId;
  int? _authUser;
  AccountInfo? _account;
  bool _loaded = false;
  File? _file;

  bool get loaded => _loaded;
  bool get isLoggedIn => _cookies != null && _cookies!.isNotEmpty;
  String? get cookies => _cookies;
  String? get visitorData => _visitorData;
  String? get brandAccountId => _brandAccountId;
  int? get authUser => _authUser;
  AccountInfo? get account => _account;

  Future<File> _sessionFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$_fileName');
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    _file = file;
    return file;
  }

  Future<void> load() async {
    try {
      final file = await _sessionFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) {
          _cookies = json['cookies'] as String?;
          _visitorData = json['visitorData'] as String?;
          _brandAccountId = json['brandAccountId'] as String?;
          final authUser = json['authUser'];
          _authUser = authUser is num ? authUser.toInt() : null;
          final account = json['account'];
          if (account is Map<String, dynamic>) {
            _account = AccountInfo(
              name: account['name'] as String? ?? '',
              handle: account['handle'] as String? ?? '',
              avatarUrl: account['avatarUrl'] as String?,
            );
          }
        }
      }
    } catch (_) {
      // A corrupted session must never block app startup.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save({
    required String cookies,
    String? visitorData,
    AccountInfo? account,
    String? brandAccountId,
    int? authUser,
  }) async {
    _cookies = cookies;
    _visitorData = visitorData ?? _visitorData;
    _account = account ?? _account;
    _brandAccountId = brandAccountId;
    _authUser = authUser;
    notifyListeners();
    try {
      final file = await _sessionFile();
      await file.writeAsString(jsonEncode({
        'cookies': _cookies,
        'visitorData': _visitorData,
        'brandAccountId': _brandAccountId,
        'authUser': _authUser,
        'account': _account == null
            ? null
            : {
                'name': _account!.name,
                'handle': _account!.handle,
                'avatarUrl': _account!.avatarUrl,
              },
      }), flush: true);
      if (!Platform.isAndroid && !Platform.isIOS) {
        await Process.run('chmod', ['600', file.path]);
      }
    } catch (_) {
      // Keep the in-memory session even if writing failed.
    }
  }

  Future<void> updateAccount(AccountInfo? account) async {
    if (account == null) return;
    _account = account;
    notifyListeners();
    await save(
      cookies: _cookies ?? '',
      visitorData: _visitorData,
      brandAccountId: _brandAccountId,
      authUser: _authUser,
    );
  }

  Future<void> clear() async {
    _cookies = null;
    _visitorData = null;
    _brandAccountId = null;
    _authUser = null;
    _account = null;
    notifyListeners();
    try {
      final file = await _sessionFile();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
