import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_translate/widgets/request_error_panel.dart';

void main() {
  testWidgets('request error exposes retry and reset actions', (tester) async {
    var retryCount = 0;
    var resetCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RequestErrorPanel(
            message: 'The service is offline.',
            onRetry: () => retryCount++,
            onReset: () => resetCount++,
          ),
        ),
      ),
    );

    expect(find.text('The service is offline.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-request')));
    await tester.pump();
    expect(retryCount, 1);
    await tester.tap(find.byKey(const Key('reset-request')));
    await tester.pump();
    expect(resetCount, 1);
  });
}
