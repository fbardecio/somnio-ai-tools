import 'package:somnio/src/content/skill_registry.dart';
import 'package:test/test.dart';

void main() {
  group('SkillRegistry.findWorkflowById', () {
    test('resolves a workflow skill by id', () {
      final skill = SkillRegistry.findWorkflowById('git_commit_format');
      expect(skill, isNotNull);
      expect(skill!.name, 'git-commit-format');
    });

    test('resolves a workflow skill by name', () {
      final skill = SkillRegistry.findWorkflowById('git-commit-format');
      expect(skill, isNotNull);
      expect(skill!.id, 'git_commit_format');
    });

    test('returns null for an unknown id', () {
      expect(SkillRegistry.findWorkflowById('does-not-exist'), isNull);
    });

    test('does not resolve audit bundle ids as workflow skills', () {
      // flutter_health is an audit bundle, not a workflow skill.
      expect(SkillRegistry.findWorkflowById('flutter_health'), isNull);
      expect(SkillRegistry.findById('flutter_health'), isNotNull);
    });
  });
}
