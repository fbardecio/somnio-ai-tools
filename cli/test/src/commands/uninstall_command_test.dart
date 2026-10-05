import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:somnio/src/commands/uninstall_command.dart';
import 'package:somnio/src/installers/skill_manifest.dart';
import 'package:test/test.dart';

/// Creates [path] with [contents], including any missing parent directories.
void _writeFile(String path, [String contents = 'x']) {
  Directory(p.dirname(path)).createSync(recursive: true);
  File(path).writeAsStringSync(contents);
}

void main() {
  group('removeAgentInstalls', () {
    late Directory home;

    setUp(() {
      home = Directory.systemTemp.createTempSync('uninstall_command_test_');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('removes Cursor execution rules, not just its commands', () {
      _writeFile(p.join(home.path, '.cursor', 'commands', 'security-audit.md'));
      _writeFile(
        p.join(home.path, '.cursor', 'somnio_rules', 'flutter', 'rules.md'),
      );

      removeAgentInstalls(home: home.path, environment: const {});

      expect(
        Directory(p.join(home.path, '.cursor', 'somnio_rules')).existsSync(),
        isFalse,
        reason: '~/.cursor/somnio_rules must not survive an uninstall',
      );
      expect(
        File(p.join(home.path, '.cursor', 'commands', 'security-audit.md'))
            .existsSync(),
        isFalse,
      );
    });

    test('removes Claude skills that exist in the registry', () {
      // Registry skills absent from the old hardcoded _allSkillNames list.
      for (final name in const [
        'python-health-audit',
        'python-best-practices',
        'dart-model-from-json',
        'optimize-claude-config',
      ]) {
        _writeFile(p.join(home.path, '.claude', 'skills', name, 'SKILL.md'));
      }

      removeAgentInstalls(home: home.path, environment: const {});

      for (final name in const [
        'python-health-audit',
        'python-best-practices',
        'dart-model-from-json',
        'optimize-claude-config',
      ]) {
        expect(
          Directory(p.join(home.path, '.claude', 'skills', name)).existsSync(),
          isFalse,
          reason: '$name is in SkillRegistry and must be uninstalled',
        );
      }
    });

    test('removes legacy v1.x Claude skills including somnio-rh/somnio-rp', () {
      for (final name in const ['somnio-fh', 'somnio-rh', 'somnio-rp']) {
        _writeFile(p.join(home.path, '.claude', 'skills', name, 'SKILL.md'));
      }

      removeAgentInstalls(home: home.path, environment: const {});

      for (final name in const ['somnio-fh', 'somnio-rh', 'somnio-rp']) {
        expect(
          Directory(p.join(home.path, '.claude', 'skills', name)).existsSync(),
          isFalse,
          reason: '$name is a legacy name and must still be cleaned up',
        );
      }
    });

    test('removes Claude symlinks left by the skills.sh installer', () {
      final target = Directory(p.join(home.path, 'src', 'security-audit'))
        ..createSync(recursive: true);
      final skillsDir = Directory(p.join(home.path, '.claude', 'skills'))
        ..createSync(recursive: true);
      Link(p.join(skillsDir.path, 'security-audit')).createSync(target.path);

      removeAgentInstalls(home: home.path, environment: const {});

      expect(
        Link(p.join(skillsDir.path, 'security-audit')).existsSync(),
        isFalse,
      );
      expect(target.existsSync(), isTrue, reason: 'symlink target is not ours');
    });

    test('removes Somnio skills recorded in the skills.sh lock', () {
      _writeFile(
        p.join(home.path, '.agents', '.skill-lock.json'),
        jsonEncode({
          'version': 3,
          'skills': {
            'security-audit': {'source': 'somnio-software/somnio-ai-tools'},
          },
        }),
      );
      _writeFile(
        p.join(home.path, '.agents', 'skills', 'security-audit', 'SKILL.md'),
        '---\nname: security-audit\n---\n',
      );

      removeAgentInstalls(home: home.path, environment: const {});

      expect(
        Directory(p.join(home.path, '.agents', 'skills', 'security-audit'))
            .existsSync(),
        isFalse,
      );
    });

    test('keeps ~/.agents/skills copies the skills.sh lock does not own', () {
      final canonical =
          p.join(home.path, '.agents', 'skills', 'security-audit', 'SKILL.md');
      _writeFile(canonical);

      removeAgentInstalls(home: home.path, environment: const {});

      expect(File(canonical).existsSync(), isTrue);
    });

    test('reports skills.sh removals and warnings', () {
      _writeFile(
        p.join(home.path, '.agents', '.skill-lock.json'),
        jsonEncode({
          'version': 3,
          'skills': {
            'fha': {'source': 'somnio-software/somnio-ai-tools'},
            'odd': {'source': 'somnio-software/somnio-ai-tools'},
          },
        }),
      );
      _writeFile(
        p.join(home.path, '.agents', 'skills', 'fha', 'SKILL.md'),
        '---\nname: fha\n---\n',
      );
      _writeFile(p.join(home.path, '.agents', 'skills', 'odd'));
      final removed = <String>[];
      final warnings = <String>[];

      removeAgentInstalls(
        home: home.path,
        environment: const {},
        onRemoved: removed.add,
        onWarning: warnings.add,
      );

      expect(removed, contains(contains('Removed skills.sh copy')));
      expect(warnings, [contains('not a directory')]);
    });

    test('removes Antigravity workflows nested under global_workflows/', () {
      _writeFile(
        p.join(home.path, '.gemini', 'antigravity', 'global_workflows',
            'somnio_flutter_health.md'),
      );
      _writeFile(
        p.join(home.path, '.gemini', 'antigravity', 'somnio_rules', 'r.md'),
      );

      removeAgentInstalls(home: home.path, environment: const {});

      expect(
        File(p.join(home.path, '.gemini', 'antigravity', 'global_workflows',
                'somnio_flutter_health.md'))
            .existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(home.path, '.gemini', 'antigravity', 'somnio_rules'))
            .existsSync(),
        isFalse,
      );
    });

    test('removes Gemini skills and its execution rules', () {
      _writeFile(
        p.join(home.path, '.gemini', 'skills', 'security_audit.md'),
      );
      _writeFile(p.join(home.path, '.gemini', 'somnio_rules', 'r.md'));

      removeAgentInstalls(home: home.path, environment: const {});

      expect(
        File(p.join(home.path, '.gemini', 'skills', 'security_audit.md'))
            .existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(home.path, '.gemini', 'somnio_rules')).existsSync(),
        isFalse,
      );
    });

    test('leaves files somnio did not install untouched', () {
      final userFiles = [
        p.join(home.path, '.claude', 'skills', 'my-own-skill', 'SKILL.md'),
        p.join(home.path, '.cursor', 'commands', 'my-command.md'),
        p.join(home.path, '.gemini', 'skills', 'my_notes.md'),
        p.join(home.path, '.agents', 'skills', 'unrelated', 'SKILL.md'),
      ];
      for (final f in userFiles) {
        _writeFile(f, 'user content');
      }

      removeAgentInstalls(home: home.path, environment: const {});

      for (final f in userFiles) {
        expect(
          File(f).existsSync(),
          isTrue,
          reason: 'uninstall must never delete user-authored $f',
        );
      }
    });

    test('reports whether anything was removed', () {
      expect(
        removeAgentInstalls(home: home.path, environment: const {}),
        isFalse,
        reason: 'nothing installed under an empty home',
      );

      _writeFile(
        p.join(home.path, '.claude', 'skills', 'security-audit', 'SKILL.md'),
      );

      expect(removeAgentInstalls(home: home.path, environment: const {}), isTrue);
    });
  });

  group('removeManifestTrackedInstalls', () {
    late Directory home;
    late Directory project;

    setUp(() {
      home = Directory.systemTemp.createTempSync('uninstall_manifest_home_');
      project = Directory.systemTemp.createTempSync('uninstall_manifest_proj_');
    });

    tearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
      if (project.existsSync()) project.deleteSync(recursive: true);
    });

    /// Installs a fake somnio skill for Claude under [root] and records it in
    /// that location's manifest, mirroring what AgentInstaller writes.
    void seedClaudeSkill(String root, String skill) {
      final dir = p.join(root, '.claude', 'skills');
      _writeFile(p.join(dir, skill, 'SKILL.md'));
      SkillManifest.load(dir)
        ..record(
          skill: skill,
          kind: 'audit',
          paths: [ManifestPath(ManifestRoot.install, skill)],
        )
        ..save();
    }

    test('removes a project-scoped install the home sweep cannot reach', () {
      seedClaudeSkill(project.path, 'security-audit');

      final removed = removeManifestTrackedInstalls(
        home: home.path,
        projectRoot: project.path,
      );

      expect(removed, isTrue);
      expect(
        Directory(
          p.join(project.path, '.claude', 'skills', 'security-audit'),
        ).existsSync(),
        isFalse,
        reason: 'project-scoped installs must be removed on uninstall',
      );
    });

    test('deletes the manifest file itself, leaving no bookkeeping behind', () {
      seedClaudeSkill(project.path, 'security-audit');
      final manifestPath = p.join(
        project.path,
        '.claude',
        'skills',
        SkillManifest.fileName,
      );
      expect(File(manifestPath).existsSync(), isTrue);

      removeManifestTrackedInstalls(
        home: home.path,
        projectRoot: project.path,
      );

      expect(File(manifestPath).existsSync(), isFalse);
    });

    test('never touches a skill absent from the manifest', () {
      seedClaudeSkill(project.path, 'security-audit');
      final mine = p.join(project.path, '.claude', 'skills', 'my-own-skill');
      _writeFile(p.join(mine, 'SKILL.md'), 'hand written');

      removeManifestTrackedInstalls(
        home: home.path,
        projectRoot: project.path,
      );

      expect(
        File(p.join(mine, 'SKILL.md')).readAsStringSync(),
        'hand written',
        reason: 'uninstall must only delete what the CLI recorded installing',
      );
    });

    test('clears both the global and the project scope in one pass', () {
      seedClaudeSkill(home.path, 'security-audit');
      seedClaudeSkill(project.path, 'flutter-health-audit');

      removeManifestTrackedInstalls(
        home: home.path,
        projectRoot: project.path,
      );

      expect(
        Directory(
          p.join(home.path, '.claude', 'skills', 'security-audit'),
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          p.join(project.path, '.claude', 'skills', 'flutter-health-audit'),
        ).existsSync(),
        isFalse,
      );
    });

    test('returns false when nothing is recorded anywhere', () {
      expect(
        removeManifestTrackedInstalls(
          home: home.path,
          projectRoot: project.path,
        ),
        isFalse,
      );
    });
  });
}
