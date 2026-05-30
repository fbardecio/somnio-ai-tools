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

  group('SkillRegistry.findById', () {
    test('resolves a bundle by its id', () {
      final skill = SkillRegistry.findById('nestjs_plan');
      expect(skill, isNotNull);
      expect(skill!.name, 'nestjs-best-practices');
    });

    test('returns null for an unknown id', () {
      expect(SkillRegistry.findById('nope'), isNull);
    });
  });

  group('SkillRegistry.findByName', () {
    test('resolves a bundle by its name', () {
      final skill = SkillRegistry.findByName('flutter-health-audit');
      expect(skill, isNotNull);
      expect(skill!.id, 'flutter_health');
    });

    test('resolves a bundle by an alias', () {
      final byLong = SkillRegistry.findByName('somnio-fh');
      final byShort = SkillRegistry.findByName('fh');
      expect(byLong?.id, 'flutter_health');
      expect(byShort?.id, 'flutter_health');
    });

    test('returns null for an unknown name or alias', () {
      expect(SkillRegistry.findByName('unknown-skill'), isNull);
    });
  });

  group('SkillRegistry.technologies', () {
    test('returns unique, sorted technology display names', () {
      final techs = SkillRegistry.technologies;
      expect(techs, ['Flutter', 'NestJS', 'React', 'Security']);
      // Sorted and de-duplicated.
      final sorted = [...techs]..sort();
      expect(techs, sorted);
    });
  });

  group('SkillRegistry.byTechnologies', () {
    test('returns bundles matching the given technologies', () {
      final bundles = SkillRegistry.byTechnologies(['Flutter']);
      expect(bundles, isNotEmpty);
      expect(bundles.every((b) => b.techDisplayName == 'Flutter'), isTrue);
      // Two Flutter bundles: health + best-practices.
      expect(bundles.map((b) => b.id),
          containsAll(['flutter_health', 'flutter_plan']));
    });

    test('returns empty when no technology matches', () {
      expect(SkillRegistry.byTechnologies(['Rust']), isEmpty);
    });
  });
}
