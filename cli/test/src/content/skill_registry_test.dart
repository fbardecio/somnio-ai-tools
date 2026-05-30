import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:somnio/src/content/skill_registry.dart';
import 'package:test/test.dart';

/// Walks up from the test's working directory until it finds the repo root
/// (the directory that contains the top-level `skills/` folder).
String _repoRoot() {
  var dir = Directory.current;
  while (true) {
    if (Directory(p.join(dir.path, 'skills')).existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('Could not locate repo root from ${Directory.current}');
    }
    dir = parent;
  }
}

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

    test('resolves optimize-claude-config by id and name', () {
      final byId = SkillRegistry.findWorkflowById('optimize_claude_config');
      final byName = SkillRegistry.findWorkflowById('optimize-claude-config');
      expect(byId, isNotNull);
      expect(byId!.name, 'optimize-claude-config');
      expect(byId.displayName, 'Optimize Claude Config');
      expect(byName?.id, 'optimize_claude_config');
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

  group('registered skill files exist on disk', () {
    final root = _repoRoot();

    test('every workflow skill has its SKILL.md present', () {
      for (final skill in SkillRegistry.workflowSkills) {
        final file = File(p.join(root, skill.planRelativePath));
        expect(
          file.existsSync(),
          isTrue,
          reason: '${skill.name}: missing ${skill.planRelativePath}',
        );
      }
    });

    test('every audit bundle has its SKILL.md present', () {
      for (final bundle in SkillRegistry.skills) {
        final file = File(p.join(root, bundle.planRelativePath));
        expect(
          file.existsSync(),
          isTrue,
          reason: '${bundle.name}: missing ${bundle.planRelativePath}',
        );
      }
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
