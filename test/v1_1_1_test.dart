// Store Admin v1.1.1 tests: refreshed Google config, blob-ST launcher
// icons at every density, and the splash contract (kept from v1.1).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:storeadmin/screens/splash_screen.dart';

int _pngDimension(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

void main() {
  test('refreshed google-services.json has OAuth clients for sign-in', () {
    final file = File('android/app/google-services.json');
    expect(file.existsSync(), isTrue);
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final project = json['project_info'] as Map<String, dynamic>;
    expect(project['project_id'], 'store-3384c');
    final clients = json['client'] as List<dynamic>;
    expect(clients, isNotEmpty);
    final client = clients.first as Map<String, dynamic>;
    final info = client['client_info'] as Map<String, dynamic>;
    final androidInfo = info['android_client_info'] as Map<String, dynamic>;
    expect(androidInfo['package_name'], 'com.valor.storeadmin');
    final oauth = client['oauth_client'] as List<dynamic>;
    expect(oauth, isNotEmpty,
        reason: 'Google sign-in needs a non-empty oauth_client list');
  });

  test('blob-ST launcher icon is a real PNG at every density', () {
    const expected = {
      'mipmap-mdpi': 48,
      'mipmap-hdpi': 72,
      'mipmap-xhdpi': 96,
      'mipmap-xxhdpi': 144,
      'mipmap-xxxhdpi': 192,
    };
    const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (final entry in expected.entries) {
      final file = File(
          'android/app/src/main/res/${entry.key}/ic_launcher.png');
      expect(file.existsSync(), isTrue, reason: entry.key);
      final bytes = file.readAsBytesSync();
      expect(bytes.length, greaterThan(100), reason: entry.key);
      for (var i = 0; i < pngMagic.length; i++) {
        expect(bytes[i], pngMagic[i], reason: '${entry.key} PNG magic');
      }
      // IHDR width/height are big-endian at offsets 16 and 20.
      expect(_pngDimension(bytes, 16), entry.value,
          reason: '${entry.key} width');
      expect(_pngDimension(bytes, 20), entry.value,
          reason: '${entry.key} height');
    }
  });

  test('splash contract unchanged: 2500ms, draw/sweep/name stages', () {
    expect(StSplashScreen.totalDuration.inMilliseconds, 2500);
    expect(stSplashStageFor(0.0), StSplashStage.drawing);
    expect(stSplashStageFor(0.40), StSplashStage.sweeping);
    expect(stSplashStageFor(0.80), StSplashStage.name);
    expect(stSplashStageFor(1.0), StSplashStage.exiting);
  });

  test('adaptive icon: navy background layer + blob foreground, no white', () {
    final xml = File(
            'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml')
        .readAsStringSync();
    expect(xml.contains('adaptive-icon'), isTrue);
    expect(xml.contains('@color/ic_launcher_background'), isTrue);
    expect(xml.contains('@mipmap/ic_launcher_foreground'), isTrue);
    final colorXml = File(
            'android/app/src/main/res/values/ic_launcher_background.xml')
        .readAsStringSync();
    // Dark navy background, never white: #071938.
    expect(colorXml.contains('#071938'), isTrue);
    expect(colorXml.contains('#FFFFFF'), isFalse);
    const foreground = {
      'mipmap-mdpi': 108,
      'mipmap-hdpi': 162,
      'mipmap-xhdpi': 216,
      'mipmap-xxhdpi': 324,
      'mipmap-xxxhdpi': 432,
    };
    for (final entry in foreground.entries) {
      final file = File(
          'android/app/src/main/res/${entry.key}/ic_launcher_foreground.png');
      expect(file.existsSync(), isTrue, reason: entry.key);
      final bytes = file.readAsBytesSync();
      expect(_pngDimension(bytes, 16), entry.value,
          reason: '${entry.key} foreground width');
      expect(_pngDimension(bytes, 20), entry.value,
          reason: '${entry.key} foreground height');
    }
  });

  test('splash mark paths are non-empty', () {
    expect(blobOutlinePath().computeMetrics().isNotEmpty, isTrue);
    expect(blobSPath().computeMetrics().isNotEmpty, isTrue);
    expect(blobTOutlinePath().computeMetrics().isNotEmpty, isTrue);
    expect(blobTFillPath().computeMetrics().isNotEmpty, isTrue);
  });
}
