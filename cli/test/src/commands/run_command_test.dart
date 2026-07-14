import 'package:somnio/src/runner/rule_names.dart';
import 'package:test/test.dart';

/// `run_command.dart` carries `// coverage:ignore-file`, so the dispatch
/// logic that used to inline these comparisons has been extracted into
/// `rule_names.dart` — a pure, testable helper. These tests cover the exact
/// bugs that a hyphen/underscore mismatch previously caused:
///
/// - Bug A: the report-generator dispatch never fired because the check
///   compared against `_report_generator` while the parser produces the
///   hyphenated `report-generator`.
/// - Bug B: pre-flight artifacts (written as `${techPrefix}_tool_installer`)
///   were never found because the lookup used the bare, hyphenated rule
///   name (`tool-installer`) instead of the mapped artifact key.
void main() {
  group('report-generator dispatch', () {
    test('"report-generator" matches kReportGeneratorRuleName', () {
      const ruleName = 'report-generator';
      expect(ruleName == kReportGeneratorRuleName, isTrue);
    });

    test('legacy "_report_generator" style name does NOT match', () {
      const ruleName = 'flutter_report_generator';
      expect(ruleName == kReportGeneratorRuleName, isFalse);
      expect(ruleName.endsWith('_report_generator'), isTrue);
    });
  });

  group('report-format-enforcer chain', () {
    test('enforcer rule name constant resolves to report-format-enforcer', () {
      expect(kReportFormatEnforcerRuleName, 'report-format-enforcer');
    });
  });

  group('preflightKey', () {
    test('maps a flutter pre-flight rule name to its artifact key', () {
      expect(
        preflightKey('flutter', 'tool-installer'),
        'flutter_tool_installer',
      );
    });

    test('maps a nestjs pre-flight rule name to its artifact key', () {
      expect(
        preflightKey('nestjs', 'version-alignment'),
        'nestjs_version_alignment',
      );
    });

    test('rule names with no hyphens pass through unchanged', () {
      expect(
        preflightKey('flutter', 'testcoverage'),
        'flutter_testcoverage',
      );
    });
  });
}
