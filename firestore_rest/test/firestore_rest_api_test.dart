import 'package:test/test.dart';
import 'test_setup.dart';

Future main() async {
  Context context = await setup();
  print(context);
  group('rest', () {
    test('basic', () {});
  }, skip: context == null);
}
