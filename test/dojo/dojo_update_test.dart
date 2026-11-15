import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maia_chess/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _asset(String name, {int size = 1234, String? digest}) => {
  'name': name,
  'size': size,
  'browser_download_url':
      'https://github.com/omgboom/chesster/releases/download/v0.2.0/$name',
  'digest': ?digest,
};

Map<String, Object?> _release({
  String tag = 'v0.2.0',
  List<Map<String, Object?>>? assets,
  bool prerelease = false,
}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': prerelease,
  'html_url': 'https://github.com/omgboom/chesster/releases/tag/$tag',
  'assets':
      assets ??
      [
        _asset('chesster-v0.2.0-1012-arm64.apk', digest: 'sha256:ABCDEF'),
        _asset('chesster-v0.2.0-1012-windows-x64.zip'),
        _asset('SHA256SUMS.txt'),
      ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('asset names', () {
    test('parses the CI build number', () {
      expect(dojoParseAssetBuildNumber('chesster-v0.1.0-1006-arm64.apk'), 1006);
      expect(
        dojoParseAssetBuildNumber('chesster-v0.1.0-1006-windows-x64.zip'),
        1006,
      );
      expect(dojoParseAssetBuildNumber('chesster-main-1100-arm64.apk'), 1100);
      expect(dojoParseAssetBuildNumber('chesster-v0.1.0-arm64.apk'), isNull);
      expect(
        dojoParseAssetBuildNumber('chesster-v0.1.0-1006-x86_64.apk'),
        isNull,
      );
      expect(
        dojoParseAssetBuildNumber('chesster-v0.1.0-1006-arm64.apk.sha256'),
        isNull,
      );
    });

    test('selects the asset for each platform', () {
      final android = dojoSelectReleaseAsset(
        _release(),
        DojoUpdatePlatform.android,
      )!;
      expect(android.assetName, 'chesster-v0.2.0-1012-arm64.apk');
      expect(android.buildNumber, 1012);
      expect(android.tag, 'v0.2.0');
      expect(android.size, 1234);
      expect(android.sha256, 'abcdef');
      expect(android.versionLabel, 'v0.2.0');

      final windows = dojoSelectReleaseAsset(
        _release(),
        DojoUpdatePlatform.windows,
      )!;
      expect(windows.assetName, 'chesster-v0.2.0-1012-windows-x64.zip');
      expect(windows.sha256, isNull);
    });

    test('ignores releases without a matching asset and prereleases', () {
      expect(
        dojoSelectReleaseAsset(
          _release(assets: [_asset('chesster-v0.2.0-1012-windows-x64.zip')]),
          DojoUpdatePlatform.android,
        ),
        isNull,
      );
      expect(
        dojoSelectReleaseAsset(
          _release(prerelease: true),
          DojoUpdatePlatform.android,
        ),
        isNull,
      );
      expect(
        dojoSelectReleaseAsset({'tag_name': 'v1'}, DojoUpdatePlatform.android),
        isNull,
      );
    });

    test('takes the highest build when several assets match', () {
      final release = _release(
        assets: [
          _asset('chesster-v0.2.0-1010-arm64.apk'),
          _asset('chesster-v0.2.0-1013-arm64.apk'),
          _asset('chesster-v0.2.0-1011-arm64.apk'),
        ],
      );
      expect(
        dojoSelectReleaseAsset(
          release,
          DojoUpdatePlatform.android,
        )!.buildNumber,
        1013,
      );
    });

    test('compares build numbers strictly', () {
      final release = dojoSelectReleaseAsset(
        _release(),
        DojoUpdatePlatform.android,
      )!;
      expect(dojoIsNewerBuild(release, 1011), isTrue);
      expect(dojoIsNewerBuild(release, 1012), isFalse);
      expect(dojoIsNewerBuild(release, 1013), isFalse);
      expect(dojoIsNewerBuild(release, null), isFalse);
    });

    test('round-trips the cached release', () {
      final release = dojoSelectReleaseAsset(
        _release(),
        DojoUpdatePlatform.android,
      )!;
      final copy = DojoReleaseInfo.fromJson(
        jsonDecode(jsonEncode(release.toJson())),
      )!;
      expect(copy.assetName, release.assetName);
      expect(copy.buildNumber, release.buildNumber);
      expect(copy.sha256, release.sha256);
    });
  });

  group('DojoUpdater.check', () {
    DojoUpdater updater(
      http.Client client,
      int current, {
      DojoUpdatePlatform platform = DojoUpdatePlatform.android,
    }) => DojoUpdater(
      client: client,
      currentBuild: () async => current,
      platform: platform,
    );

    test(
      'queries the latest release with a User-Agent and finds a newer build',
      () async {
        late http.Request seen;
        final client = MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(_release()), 200);
        });
        final u = updater(client, 1006);
        await u.check();
        expect(seen.url.toString(), dojoUpdateLatestReleaseUrl);
        expect(seen.headers['User-Agent'], dojoUpdateUserAgent);
        expect(u.status, DojoUpdateStatus.available);
        expect(u.hasUpdate, isTrue);
        expect(u.release!.buildNumber, 1012);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt(dojoUpdateCheckedAtKey), isNotNull);
        expect(prefs.getString(dojoUpdateCachedReleaseKey), contains('1012'));
      },
    );

    test('reports up to date for the same or an older build', () async {
      final client = MockClient(
        (_) async => http.Response(jsonEncode(_release()), 200),
      );
      final u = updater(client, 1012, platform: DojoUpdatePlatform.windows);
      await u.check();
      expect(u.status, DojoUpdateStatus.upToDate);
      expect(u.hasUpdate, isFalse);
      expect(u.release, isNull);
    });

    test('surfaces HTTP errors unless quiet', () async {
      final client = MockClient(
        (_) async => http.Response('{"message":"rate limited"}', 403),
      );
      final loud = updater(client, 1006);
      await loud.check();
      expect(loud.status, DojoUpdateStatus.error);
      expect(loud.message, contains('rate limit'));
      expect(loud.hasUpdate, isFalse);

      final quiet = updater(client, 1006);
      await quiet.check(quiet: true);
      expect(quiet.status, DojoUpdateStatus.idle);
    });

    test('treats a repository without releases as up to date', () async {
      final client = MockClient(
        (_) async => http.Response('{"message":"Not Found"}', 404),
      );
      final u = updater(client, 1006);
      await u.check();
      expect(u.status, DojoUpdateStatus.upToDate);
    });
  });

  testWidgets('banner is hidden until an update is found', (tester) async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode(_release()), 200),
    );
    final u = DojoUpdater(
      client: client,
      currentBuild: () async => 1006,
      platform: DojoUpdatePlatform.android,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              DojoUpdateBanner(updater: u),
              DojoUpdateTile(updater: u),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('dojo-update-banner')), findsNothing);
    expect(find.text('Check for updates'), findsOneWidget);
    await tester.runAsync(u.check);
    await tester.pump();
    expect(find.byKey(const ValueKey('dojo-update-banner')), findsOneWidget);
    expect(find.text('Update available: v0.2.0 (build 1012)'), findsWidgets);
    expect(find.text('Update'), findsNWidgets(2));
  });
}
