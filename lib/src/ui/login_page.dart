import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../api/youtube_music_api.dart';
import '../auth/login_service.dart';
import '../auth/session_store.dart';
import 'theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _loginService = LoginService();
  InAppWebViewController? _webView;
  final _pasteController = TextEditingController();
  bool _busy = false;
  String? _message;

  bool get _showWebView => !kIsWeb && Platform.isAndroid;

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }

  Future<void> _finishWebViewLogin() async {
    final controller = _webView;
    if (controller == null) return;
    setState(() {
      _busy = true;
      _message = 'Lendo a sessão do Google…';
    });
    try {
      final cookieManager = CookieManager.instance();
      final pairs = <String>[];
      for (final url in const [
        'https://music.youtube.com',
        'https://www.youtube.com',
      ]) {
        final cookies = await cookieManager.getCookies(url: WebUri(url));
        for (final cookie in cookies) {
          if (cookie.value.isEmpty) continue;
          pairs.add('${cookie.name}=${cookie.value}');
        }
      }
      final header = LoginService.normalizeCookieHeader(pairs.join('; '));
      if (header == null) {
        setState(() {
          _busy = false;
          _message =
              'Login ainda não concluído. Entre na sua conta e toque em "Concluir" de novo.';
        });
        return;
      }
      await _saveSession(header);
    } catch (error) {
      setState(() {
        _busy = false;
        _message = 'Não foi possível ler os cookies: $error';
      });
    }
  }

  Future<void> _saveSession(
    String header, {
    String? visitorData,
    String? brandAccountId,
  }) async {
    final api = context.read<YouTubeMusicApi>();
    final session = context.read<SessionStore>();
    setState(() {
      _busy = true;
      _message = 'Validando a conta…';
    });
    api.updateSession(cookies: header, brandAccountId: brandAccountId);
    // Reads DELEGATED_SESSION_ID/SESSION_INDEX from the logged-in page, which is
    // what identifies the brand account (conta de marca) of the session.
    await api.refreshSession();
    final account = await api.accountInfo();
    final visitor = visitorData ?? await api.visitorData();
    await session.save(
      cookies: header,
      visitorData: visitor,
      account: account,
      brandAccountId: api.brandAccountId,
      authUser: api.authUser,
    );
    if (!mounted) return;
    if (account == null) {
      setState(() {
        _busy = false;
        _message =
            'Sessão salva, mas o YouTube não confirmou a conta. Alguns recursos da biblioteca podem falhar.';
      });
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _setBrandAccount() async {
    final session = context.read<SessionStore>();
    final cookies = session.cookies;
    if (cookies == null || cookies.isEmpty) return;
    final controller =
        TextEditingController(text: session.brandAccountId ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Conta de marca'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cole o ID numérico da conta de marca (o número que aparece '
                'em myaccount.google.com/brandaccounts, na URL '
                'myaccount.google.com/b/ID). Deixe vazio para usar somente a '
                'conta Google padrão.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  hintText: '104463538996161958726',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('Aplicar'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null) return;
    if (result.isEmpty) {
      await _saveSession(cookies, brandAccountId: null);
      return;
    }
    final match = RegExp(r'\d{10,}').firstMatch(result);
    if (match == null) {
      setState(() => _message =
          'Não encontrei um ID de conta de marca nesse texto. Cole apenas os números.');
      return;
    }
    await _saveSession(cookies, brandAccountId: match.group(0));
  }

  Future<void> _importFromFirefox() async {
    setState(() {
      _busy = true;
      _message = 'Procurando o perfil do Firefox…';
    });
    final result = await _loginService.importFromFirefox();
    if (!mounted) return;
    if (!result.found) {
      final roots = result.searchedRoots.isEmpty
          ? 'nenhuma pasta padrão (~/.mozilla/firefox, ~/.config/mozilla/firefox)'
          : result.searchedRoots.join(', ');
      setState(() {
        _busy = false;
        _message = result.profilesChecked == 0
            ? 'Não encontrei o Firefox em: $roots. Se o perfil estiver em outro '
                'lugar, use "Colar cookies".'
            : 'Achei ${result.profilesChecked} perfil(is) do Firefox, mas nenhum '
                'tem cookies de login do YouTube. Faça login em '
                'music.youtube.com no Firefox e feche a janela antes de importar.';
      });
      return;
    }
    await _saveSession(result.cookies!);
  }

  Future<void> _openPasteDialog() async {
    _pasteController.clear();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Colar cookies'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cole o cabeçalho Cookie copiado do DevTools, um cookies.txt '
                'ou um JSON de cookies. Precisa conter SAPISID ou '
                '__Secure-3PAPISID.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pasteController,
                maxLines: 6,
                minLines: 4,
                decoration: const InputDecoration(
                  hintText: 'SAPISID=...; APISID=...; SID=...',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _pasteController.text.trim()),
              child: const Text('Importar'),
            ),
          ],
        );
      },
    );
    if (result == null || result.isEmpty) return;
    final header = LoginService.parsePasted(result);
    if (header == null) {
      setState(() => _message =
          'Não encontrei cookies de autenticação nesse texto. Inclua SAPISID e APISID.');
      return;
    }
    await _saveSession(header);
  }

  Future<void> _logout() async {
    final api = context.read<YouTubeMusicApi>();
    final session = context.read<SessionStore>();
    api.updateSession(cookies: '');
    await session.clear();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Conta Google'),
        actions: [
          if (_showWebView)
            TextButton(
              onPressed: _busy ? null : _finishWebViewLogin,
              child: const Text('Concluir'),
            ),
          if (session.isLoggedIn)
            IconButton(
              tooltip: 'Sair',
              onPressed: _busy ? null : _logout,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_message != null)
            Container(
              width: double.infinity,
              color: AppColors.surfaceHigh,
              padding: const EdgeInsets.all(12),
              child: Text(
                _message!,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
          if (session.isLoggedIn)
            _AccountCard(
              name: session.account?.name ?? 'Conta conectada',
              handle: session.account?.handle ?? '',
              avatar: session.account?.avatarUrl,
            ),
          if (session.isLoggedIn)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: _OptionTile(
                icon: Icons.switch_account,
                title: 'Conta de marca',
                subtitle: session.brandAccountId == null
                    ? 'Nenhuma detectada. Toque para informar o ID do canal '
                        '(conta de marca).'
                    : 'Canal ativo: ${session.account?.name ?? 'conta de marca'} '
                        '(ID ${session.brandAccountId}). Toque para trocar.',
                onTap: _busy ? null : _setBrandAccount,
              ),
            ),
          if (_showWebView)
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(
                    'https://accounts.google.com/ServiceLogin'
                    '?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F',
                  ),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  useHybridComposition: true,
                  mediaPlaybackRequiresUserGesture: false,
                  isInspectable: true,
                  userAgent:
                      'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/126.0.0.0 Mobile Safari/537.36',
                ),
                onWebViewCreated: (controller) => _webView = controller,
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'Entre na sua conta Google',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'A conta é usada apenas para acessar sua biblioteca, '
                    'curtidas e playlists do YouTube Music. Os cookies ficam '
                    'salvos localmente, neste computador.',
                    style: TextStyle(color: AppColors.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 22),
                  _OptionTile(
                    icon: Icons.open_in_new,
                    title: 'Abrir music.youtube.com no navegador',
                    subtitle:
                        'Faça login no navegador e depois importe os cookies.',
                    onTap: _busy
                        ? null
                        : () => _loginService.openLoginInBrowser(),
                  ),
                  if (_loginService.canImportFromBrowser)
                    _OptionTile(
                      icon: Icons.travel_explore,
                      title: 'Importar do Firefox',
                      subtitle:
                          'Lê o cookies.sqlite do seu perfil mais recente. '
                          'Feche a janela de login do Firefox antes de importar.',
                      onTap: _busy ? null : _importFromFirefox,
                    ),
                  _OptionTile(
                    icon: Icons.content_paste,
                    title: 'Colar cookies',
                    subtitle:
                        'Funciona com Chrome, Firefox, Brave e qualquer navegador '
                        'que exporte cookies.',
                    onTap: _busy ? null : _openPasteDialog,
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 24),
                    const Center(
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.accent),
                    ),
                  ],
                  const SizedBox(height: 18),
                  const Text(
                    'Dica: no Android, o login dentro do app pode ser bloqueado '
                    'pelo Google. Se isso acontecer, use "Colar cookies" ou abra '
                    'a conta pelo navegador do sistema. Para usar uma conta de '
                    'marca, selecione o canal no site antes de copiar os cookies; '
                    'o app também aceita o ID numérico em "Conta de marca".',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.name,
    required this.handle,
    this.avatar,
  });

  final String name;
  final String handle;
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.surface,
            backgroundImage: avatar == null ? null : NetworkImage(avatar!),
            child: avatar == null ? const Icon(Icons.person) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (handle.isNotEmpty)
                  Text(handle,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const Icon(Icons.verified, size: 18, color: AppColors.accent),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, color: AppColors.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
