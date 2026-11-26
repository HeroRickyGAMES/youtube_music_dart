import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_music_player_dart/src/api/innertube_parser.dart';

void main() {
  test('accountFrom detects the active brand account id', () {
    final response = {
      'actions': [
        {
          'openPopupAction': {
            'popup': {
              'multiPageMenuRenderer': {
                'header': {
                  'activeAccountHeaderRenderer': {
                    'accountName': {
                      'runs': [
                        {'text': 'HeroRicky_Games'},
                      ],
                    },
                    'channelHandle': {
                      'runs': [
                        {'text': '@HeroRickyGames'},
                      ],
                    },
                    'manageAccountTitle': {
                      'runs': [
                        {
                          'text': 'Gerenciar sua Conta do Google',
                          'navigationEndpoint': {
                            'urlEndpoint': {
                              'url': 'https://myaccount.google.com/u/1/b/'
                                  '104463538996161958726/?utm_source=YouTubeWeb',
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
        },
      ],
    };

    final account = accountFrom(response);

    expect(account, isNotNull);
    expect(account!.name, 'HeroRicky_Games');
    expect(account.handle, '@HeroRickyGames');
    expect(account.brandAccountId, '104463538996161958726');
  });

  test('accountFrom returns null without an active account header', () {
    expect(accountFrom(const {'actions': []}), isNull);
  });
}
