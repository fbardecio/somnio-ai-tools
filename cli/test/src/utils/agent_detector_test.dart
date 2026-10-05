import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:somnio/src/utils/agent_detector.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('agent_detector_test_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('AgentDetector', () {
    group('hasContent', () {
      test('is false for a missing directory', () {
        expect(AgentDetector.hasContent(p.join(temp.path, 'none')), isFalse);
      });

      test('is false for an empty directory', () {
        expect(AgentDetector.hasContent(temp.path), isFalse);
      });

      test('ignores .DS_Store', () {
        File(p.join(temp.path, '.DS_Store')).writeAsStringSync('x');

        expect(AgentDetector.hasContent(temp.path), isFalse);
      });

      test('is true when the directory holds a skill', () {
        Directory(p.join(temp.path, 'some-skill')).createSync();

        expect(AgentDetector.hasContent(temp.path), isTrue);
      });

      test(
        'is false when the directory cannot be listed',
        () {
          Directory(p.join(temp.path, 'x')).createSync();
          Process.runSync('chmod', ['000', temp.path]);
          addTearDown(() => Process.runSync('chmod', ['755', temp.path]));

          expect(AgentDetector.hasContent(temp.path), isFalse);
        },
        testOn: 'posix',
      );
    });
  });
}
