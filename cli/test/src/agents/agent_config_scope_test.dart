import 'package:somnio/src/agents/agent_config.dart';
import 'package:test/test.dart';

void main() {
  group('supportsProjectScope', () {
    test('is true for a home-anchored installPath', () {
      const agent = AgentConfig(
        id: 'claude',
        displayName: 'Claude Code',
        installPath: '{home}/.claude/skills/{name}',
      );

      expect(agent.supportsProjectScope, isTrue);
    });

    test('is false for an installPath that is not home-anchored', () {
      const agent = AgentConfig(
        id: 'weird-agent',
        displayName: 'Weird Agent',
        installPath: '/opt/weird-agent/skills/{name}',
      );

      expect(agent.supportsProjectScope, isFalse);
    });
  });

  group('resolvedScopedInstallPath', () {
    const agent = AgentConfig(
      id: 'claude',
      displayName: 'Claude Code',
      installPath: '{home}/.claude/skills/{name}',
    );

    test('InstallScope.global anchors at home', () {
      final resolved = agent.resolvedScopedInstallPath(
        scope: InstallScope.global,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'security-audit',
      );

      expect(resolved, '/Users/me/.claude/skills/security-audit');
    });

    test('InstallScope.project anchors at the project root', () {
      final resolved = agent.resolvedScopedInstallPath(
        scope: InstallScope.project,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'security-audit',
      );

      expect(
        resolved,
        '/Users/me/projects/app/.claude/skills/security-audit',
      );
    });
  });

  group('resolvedScopedExecutionRulesPath', () {
    const agentWithRulesPath = AgentConfig(
      id: 'cursor',
      displayName: 'Cursor',
      installPath: '{home}/.cursor/commands/{name}',
      executionRulesPath: '{home}/.cursor/somnio_rules/{name}',
    );

    test('InstallScope.global anchors at home', () {
      final resolved = agentWithRulesPath.resolvedScopedExecutionRulesPath(
        scope: InstallScope.global,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'flutter',
      );

      expect(resolved, '/Users/me/.cursor/somnio_rules/flutter');
    });

    test('InstallScope.project anchors at the project root', () {
      final resolved = agentWithRulesPath.resolvedScopedExecutionRulesPath(
        scope: InstallScope.project,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'flutter',
      );

      expect(
        resolved,
        '/Users/me/projects/app/.cursor/somnio_rules/flutter',
      );
    });

    test('falls back to installPath when executionRulesPath is null', () {
      const agentWithoutRulesPath = AgentConfig(
        id: 'claude',
        displayName: 'Claude Code',
        installPath: '{home}/.claude/skills/{name}',
      );

      final global = agentWithoutRulesPath.resolvedScopedExecutionRulesPath(
        scope: InstallScope.global,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'security-audit',
      );
      final project = agentWithoutRulesPath.resolvedScopedExecutionRulesPath(
        scope: InstallScope.project,
        home: '/Users/me',
        projectRoot: '/Users/me/projects/app',
        name: 'security-audit',
      );

      expect(
        global,
        '/Users/me/.claude/skills/security-audit',
        reason: 'with no executionRulesPath, rules must resolve from the '
            'same template as installPath',
      );
      expect(
        project,
        '/Users/me/projects/app/.claude/skills/security-audit',
      );
    });
  });
}
