import 'package:deck_builder/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets('settings show the installed version and version code', (
    tester,
  ) async {
    PackageInfo.setMockInitialValues(
      appName: 'Test',
      packageName: 'app',
      version: '1.2.3',
      buildNumber: '1023',
      buildSignature: '',
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppVersionTile())),
    );
    await tester.pumpAndSettle();
    expect(find.text('1.2.3 · 빌드 1023'), findsOneWidget);
  });
}
