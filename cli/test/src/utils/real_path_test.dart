import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:somnio/src/utils/real_path.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('real_path_test_');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('realPathOf', () {
    test('resolves a path reached through a symlink', () {
      final real = Directory(p.join(temp.path, 'real', 'skills'))
        ..createSync(recursive: true);
      Link(p.join(temp.path, 'alias')).createSync(p.join(temp.path, 'real'));

      expect(
        realPathOf(p.join(temp.path, 'alias', 'skills')),
        real.resolveSymbolicLinksSync(),
      );
    });

    test('treats the same missing path under twin parents as equal', () {
      Directory(p.join(temp.path, 'real')).createSync();
      Link(p.join(temp.path, 'alias')).createSync(p.join(temp.path, 'real'));

      expect(
        realPathOf(p.join(temp.path, 'alias', '.claude', 'skills')),
        realPathOf(p.join(temp.path, 'real', '.claude', 'skills')),
      );
    });

    test('normalizes dot segments', () {
      expect(
        realPathOf(p.join(temp.path, 'a', '..', 'b')),
        realPathOf(p.join(temp.path, 'b')),
      );
    });
  });
}
