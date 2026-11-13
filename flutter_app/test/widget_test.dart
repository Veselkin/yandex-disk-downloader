import 'package:flutter_test/flutter_test.dart';

import 'package:yandex_disk_downloader/main.dart';

void main() {
  testWidgets('Приложение запускается', (WidgetTester tester) async {
    await tester.pumpWidget(const App());

    expect(find.byType(App), findsOneWidget);
    expect(find.text('Публичная ссылка'), findsOneWidget);
    expect(find.text('Папка назначения'), findsOneWidget);
    expect(find.text('Скачать'), findsOneWidget);
  });
}
