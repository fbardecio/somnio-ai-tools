// coverage:ignore-file
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../agents/agent_config.dart';
import '../agents/agent_registry.dart';
import '../content/skill_bundle.dart';
import '../content/skill_registry.dart';
import '../content/workflow_skill.dart';
import '../installers/agent_installer.dart';
import '../installers/interactive_install.dart';
import '../installers/skill_manifest.dart';
import '../utils/command_helpers.dart';
import '../utils/platform_utils.dart';
import '../utils/prompts.dart';

/// Top-level `somnio skills` command — manage installed skill bundles.
///
/// Skills are versioned and updated independently of the CLI binary
/// (`somnio update`), so this group owns their whole lifecycle: choosing
/// where they land (`install`), refreshing them in place (`update`), and
/// tearing them down again (`remove`) — all scoped per agent and per
/// [InstallScope].
class SkillsCommand extends Command<int> {
  SkillsCommand({required Logger logger}) {
    addSubcommand(_SkillsInstallCommand(logger: logger));
    addSubcommand(_SkillsUpdateCommand(logger: logger));
    addSubcommand(_SkillsRemoveCommand(logger: logger));
  }

  @override
  String get name => 'skills';

  @override
  String get description =>
      'Install, update and remove Somnio skills (global or per project).';
}

// ── Shared helpers ──────────────────────────────────────────────────────────

/// Human-readable label for an [InstallScope], used in every subcommand's
/// prompts and summary lines.
String _scopeLabel(InstallScope scope) =>
    scope == InstallScope.global ? 'global' : 'project';

/// Looks up a registered audit bundle by its installed name (what a
/// manifest entry's `skill` field records — [SkillBundle.name], not
/// [SkillBundle.id]).
SkillBundle? _findAuditByName(String name) {
  for (final bundle in SkillRegistry.skills) {
    if (bundle.name == name) return bundle;
  }
  return null;
}

/// Looks up a registered workflow skill by its installed name (see
/// [_findAuditByName]).
WorkflowSkill? _findWorkflowByName(String name) {
  for (final skill in SkillRegistry.workflowSkills) {
    if (skill.name == name) return skill;
  }
  return null;
}

// ── Install subcommand ───────────────────────────────────────────────────────

class _SkillsInstallCommand extends Command<int> {
  _SkillsInstallCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'agent',
        abbr: 'a',
        help: 'Target agent to install to.',
        allowed: AgentRegistry.installableAgents.map((a) => a.id).toList(),
      )
      ..addFlag(
        'all-agents',
        help: 'Install to all agents detected on this machine.',
      )
      ..addOption(
        'skills',
        abbr: 's',
        help: 'Comma-separated skill ids/names to install (skips the wizard).',
      )
      ..addFlag(
        'all-skills',
        help: 'Install every skill without prompting for a selection.',
      )
      ..addFlag(
        'global',
        abbr: 'g',
        help: 'Install globally (agent config dir). Mutually exclusive '
            'with --project.',
      )
      ..addFlag(
        'project',
        abbr: 'p',
        help: 'Install in the current project directory. Mutually '
            'exclusive with --global.',
      );
  }

  final Logger _logger;

  @override
  String get name => 'install';

  @override
  String get description =>
      'Install Somnio skills to one or more agents, globally or per '
      'project.\n'
      '\n'
      'Examples:\n'
      '  somnio skills install                                       # interactive\n'
      '  somnio skills install --agent claude --all-skills --global\n'
      '  somnio skills install --all-agents --project '
      '--skills flutter_health,security_audit';

  @override
  Future<int> run() async {
    final forceGlobal = argResults!['global'] as bool;
    final forceProject = argResults!['project'] as bool;

    if (forceGlobal && forceProject) {
      _logger.err('Use either --global or --project, not both.');
      return ExitCode.usage.code;
    }

    final ResolvedContent content;
    try {
      content = await CommandHelpers.resolveContent();
    } catch (e) {
      _logger.err('$e');
      return ExitCode.software.code;
    }

    final flow = InteractiveInstall(_logger);

    final agents = await _resolveAgents(flow);
    if (agents == null) return ExitCode.usage.code;
    if (agents.isEmpty) {
      _logger.info('No agents selected.');
      return ExitCode.success.code;
    }

    final selection = _resolveSkills(flow);
    if (selection == null) return ExitCode.usage.code;
    if (selection.isEmpty) {
      _logger.info('No skills selected.');
      return ExitCode.success.code;
    }

    final InstallScope scope;
    if (forceGlobal) {
      scope = InstallScope.global;
    } else if (forceProject) {
      scope = InstallScope.project;
    } else if (Prompts.isInteractive) {
      scope = _promptForScope(agents);
    } else {
      // No terminal to prompt on (CI, pipes): default to global rather
      // than hang, matching the non-interactive fallback used everywhere
      // else in this command group.
      scope = InstallScope.global;
    }

    return _installTo(agents, scope, selection, content);
  }

  // ── Agent resolution ────────────────────────────────────────────────────

  /// Returns the agents to install to, or `null` on a usage error.
  Future<List<AgentConfig>?> _resolveAgents(InteractiveInstall flow) async {
    final allAgents = argResults!['all-agents'] as bool;
    final agentId = argResults!['agent'] as String?;

    if (allAgents) {
      return flow.detectedAgents();
    }

    if (agentId != null) {
      final agent = AgentRegistry.findById(agentId);
      if (agent == null) {
        _logger.err('Unknown agent: $agentId');
        return null;
      }
      return [agent];
    }

    if (Prompts.isInteractive) {
      return flow.promptForAgents();
    }

    _logger.err('Specify --agent <id> or --all-agents.');
    return null;
  }

  // ── Skill resolution ─────────────────────────────────────────────────────

  /// Returns the skills to install, or `null` on a usage error.
  SkillSelection? _resolveSkills(InteractiveInstall flow) {
    final allSkills = argResults!['all-skills'] as bool;
    final skillsCsv = argResults!['skills'] as String?;

    if (allSkills) {
      return SkillSelection.all();
    }

    if (skillsCsv != null) {
      return _parseSkillsCsv(skillsCsv);
    }

    if (Prompts.isInteractive) {
      return flow.promptForSkills();
    }

    // No terminal to prompt on: install everything so CI never hangs.
    return SkillSelection.all();
  }

  /// Resolves a comma-separated list of skill ids/names against the registry.
  SkillSelection? _parseSkillsCsv(String csv) {
    final ids = csv.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);

    final audit = <SkillBundle>[];
    final workflow = <WorkflowSkill>[];
    final unknown = <String>[];

    for (final id in ids) {
      final bundle = SkillRegistry.findById(id) ?? SkillRegistry.findByName(id);
      if (bundle != null) {
        audit.add(bundle);
        continue;
      }
      final wf = SkillRegistry.findWorkflowById(id);
      if (wf != null) {
        workflow.add(wf);
        continue;
      }
      unknown.add(id);
    }

    if (unknown.isNotEmpty) {
      _logger.err('Unknown skill(s): ${unknown.join(', ')}');
      _logger.info('');
      _logger.info('Available skills:');
      for (final s in SkillRegistry.skills) {
        _logger.info('  ${s.id.padRight(18)} ${s.displayName}');
      }
      for (final s in SkillRegistry.workflowSkills) {
        _logger.info('  ${s.id.padRight(18)} ${s.displayName}');
      }
      return null;
    }

    return SkillSelection(audit, workflow);
  }

  // ── Scope resolution ─────────────────────────────────────────────────────

  /// Interactively asks for global vs. project scope, showing the actual
  /// resolved path for each option when there's exactly one target agent —
  /// with more than one, a single path would be misleading since each
  /// agent resolves to a different directory.
  InstallScope _promptForScope(List<AgentConfig> agents) {
    var globalLabel = 'global  (agent config dir)';
    var projectLabel = 'project (current directory)';

    if (agents.length == 1) {
      final agent = agents.single;
      final home = PlatformUtils.homeDirectory;
      final projectRoot = Directory.current.path;
      final globalPath = agent.resolvedScopedInstallPath(
        scope: InstallScope.global,
        home: home,
        projectRoot: projectRoot,
      );
      final projectPath = agent.resolvedScopedInstallPath(
        scope: InstallScope.project,
        home: home,
        projectRoot: projectRoot,
      );
      globalLabel = 'global  ($globalPath)';
      projectLabel = 'project ($projectPath)';
    }

    final index = Prompts.selectOne(
      prompt: 'Install scope',
      options: [globalLabel, projectLabel],
    );
    return index == 0 ? InstallScope.global : InstallScope.project;
  }

  // ── Install ───────────────────────────────────────────────────────────

  Future<int> _installTo(
    List<AgentConfig> agents,
    InstallScope scope,
    SkillSelection selection,
    ResolvedContent content,
  ) async {
    var totalFailed = 0;

    for (final agent in agents) {
      var effectiveScope = scope;
      if (scope == InstallScope.project && !agent.supportsProjectScope) {
        _logger.warn(
          '  ${agent.displayName}: no project install location — '
          'installing globally instead.',
        );
        effectiveScope = InstallScope.global;
      }

      final progress = _logger.progress(agent.displayName);

      final installer = AgentInstaller(
        logger: _logger,
        loader: content.loader,
        agentConfig: agent,
        scope: effectiveScope,
        projectRoot: Directory.current.path,
      );

      final result = await installer.install(bundles: selection.audit);
      final wf = installer.installWorkflowSkillsDetailed(selection.workflow);
      final total = result.skillCount + wf.installed;
      final failed = result.failedCount + wf.failed;
      totalFailed += failed;

      final label = agent.contentLabel;
      final plural = total == 1 ? label : '${label}s';
      final parts = <String>['$total $plural'];
      if (result.skippedCount > 0) {
        parts.add('${result.skippedCount} skipped');
      }
      if (failed > 0) {
        parts.add('$failed failed');
      }

      final line = '${agent.displayName}  ${parts.join(', ')}';
      if (total == 0 && failed > 0) {
        progress.fail(line);
      } else {
        progress.complete(line);
      }
      _logger.info('  Location: ${result.targetDirectory}');
    }

    return totalFailed > 0 ? ExitCode.software.code : ExitCode.success.code;
  }
}

// ── Update subcommand ────────────────────────────────────────────────────────

/// One (agent, scope) location with an installed manifest to refresh.
typedef _UpdateUnit = ({
  AgentConfig agent,
  InstallScope scope,
  SkillSelection selection,
});

class _SkillsUpdateCommand extends Command<int> {
  _SkillsUpdateCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'agent',
        abbr: 'a',
        help: 'Limit the refresh to a single agent.',
        allowed: AgentRegistry.installableAgents.map((a) => a.id).toList(),
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show the install directory for each refreshed location.',
        negatable: false,
      );
  }

  final Logger _logger;
  bool _verbose = false;

  @override
  String get name => 'update';

  @override
  String get description =>
      'Refresh already-installed skills in place, overwriting them with '
      'the shipped version. Checks both the global and project scopes for '
      'every agent and refreshes whatever it finds there — it never '
      'installs anything new and never asks global-vs-project.\n'
      '\n'
      'Examples:\n'
      '  somnio skills update                # refresh everything installed\n'
      '  somnio skills update --agent claude # refresh only Claude Code\n'
      '  somnio skills update --verbose';

  @override
  Future<int> run() async {
    final agentId = argResults!['agent'] as String?;
    _verbose = argResults!['verbose'] as bool;

    final ResolvedContent content;
    try {
      content = await CommandHelpers.resolveContent();
    } catch (e) {
      _logger.err('$e');
      return ExitCode.software.code;
    }

    List<AgentConfig> agents;
    if (agentId != null) {
      final agent = AgentRegistry.findById(agentId);
      if (agent == null) {
        _logger.err('Unknown agent: $agentId');
        return ExitCode.usage.code;
      }
      agents = [agent];
    } else {
      agents = AgentRegistry.installableAgents;
    }

    final units = _discoverUnits(agents);

    if (units.isEmpty) {
      _logger.info('No somnio-installed skills found.');
      _logger.info('Run "somnio skills install" to install skills.');
      return ExitCode.success.code;
    }

    var anyFailed = false;

    for (final unit in units) {
      final label = '${unit.agent.displayName} (${_scopeLabel(unit.scope)})';
      final progress = _logger.progress(label);

      final installer = AgentInstaller(
        logger: _logger,
        loader: content.loader,
        agentConfig: unit.agent,
        scope: unit.scope,
        projectRoot: Directory.current.path,
      );

      final result = await installer.install(bundles: unit.selection.audit);
      final wf = installer.installWorkflowSkillsDetailed(
        unit.selection.workflow,
      );
      final total = result.skillCount + wf.installed;
      final failed = result.failedCount + wf.failed;
      if (failed > 0) anyFailed = true;

      final line = '$label  $total skills updated';
      if (failed > 0) {
        progress.fail('$line, $failed failed');
      } else {
        progress.complete(line);
      }
      if (_verbose) {
        _logger.info('  Location: ${result.targetDirectory}');
      }
    }

    return anyFailed ? ExitCode.software.code : ExitCode.success.code;
  }

  /// Finds every (agent, scope) location with a non-empty
  /// `.somnio-skills.json` manifest and maps its recorded entries back to
  /// the current registry.
  ///
  /// A manifest entry whose skill no longer exists in the registry (a
  /// skill that was removed from a later CLI release) is reported via
  /// [Logger.warn] and skipped rather than silently dropped, so the user
  /// knows to run `somnio skills remove` to clean it up.
  List<_UpdateUnit> _discoverUnits(List<AgentConfig> agents) {
    final home = PlatformUtils.homeDirectory;
    final projectRoot = Directory.current.path;
    final units = <_UpdateUnit>[];

    for (final agent in agents) {
      final scopes = [
        InstallScope.global,
        if (agent.supportsProjectScope) InstallScope.project,
      ];

      for (final scope in scopes) {
        final dir = agent.resolvedScopedInstallPath(
          scope: scope,
          home: home,
          projectRoot: projectRoot,
        );
        final manifest = SkillManifest.load(dir);
        if (manifest.isEmpty) continue;

        final audit = <SkillBundle>[];
        final workflow = <WorkflowSkill>[];

        for (final entry in manifest.entries) {
          if (entry.kind == 'workflow') {
            final wf = _findWorkflowByName(entry.skill);
            if (wf == null) {
              _warnOrphaned(agent, scope, entry.skill);
              continue;
            }
            workflow.add(wf);
          } else {
            final bundle = _findAuditByName(entry.skill);
            if (bundle == null) {
              _warnOrphaned(agent, scope, entry.skill);
              continue;
            }
            audit.add(bundle);
          }
        }

        if (audit.isEmpty && workflow.isEmpty) continue;

        units.add((
          agent: agent,
          scope: scope,
          selection: SkillSelection(audit, workflow),
        ));
      }
    }

    return units;
  }

  void _warnOrphaned(AgentConfig agent, InstallScope scope, String skill) {
    _logger.warn(
      '  ${agent.displayName} (${_scopeLabel(scope)}): $skill is no '
      'longer shipped — run "somnio skills remove" to delete it.',
    );
  }
}

// ── Remove subcommand ────────────────────────────────────────────────────────

/// A skill installed at one (agent, scope) location, discovered from that
/// location's manifest — the only source `remove` ever deletes from. See
/// [_SkillsRemoveCommand] for why that matters.
typedef _RemoveCandidate = ({
  AgentConfig agent,
  InstallScope scope,
  SkillManifest manifest,
  ManifestEntry entry,
});

/// `somnio skills remove` (alias: `somnio skills uninstall`).
///
/// SAFETY GUARANTEE: only skills recorded in a location's
/// `.somnio-skills.json` manifest are ever considered for deletion. A
/// skill directory the user wrote by hand, or one a different tool
/// installed, never appears in that manifest and therefore can never be
/// picked, selected, or removed by this command — no matter what name or
/// flag is passed.
class _SkillsRemoveCommand extends Command<int> {
  _SkillsRemoveCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'agent',
        abbr: 'a',
        help: 'Limit removal to a single agent.',
        allowed: AgentRegistry.installableAgents.map((a) => a.id).toList(),
      )
      ..addOption(
        'skills',
        abbr: 's',
        help: 'Comma-separated skill names to remove.',
      )
      ..addFlag(
        'all-skills',
        help: 'Remove every somnio-installed skill in the selected scope.',
      )
      ..addFlag(
        'global',
        abbr: 'g',
        help: 'Only consider the global install. Mutually exclusive with '
            '--project.',
      )
      ..addFlag(
        'project',
        abbr: 'p',
        help: 'Only consider the project install. Mutually exclusive with '
            '--global.',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Skip the confirmation prompt.',
        negatable: false,
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Show each removed path.',
        negatable: false,
      );
  }

  final Logger _logger;
  bool _verbose = false;

  @override
  String get name => 'remove';

  @override
  List<String> get aliases => const ['uninstall'];

  @override
  String get description =>
      'Remove installed Somnio skills. Only skills recorded in the '
      '.somnio-skills.json manifest — i.e. skills this CLI itself '
      'installed — are ever candidates for deletion; hand-authored '
      'skills are never touched.\n'
      '\n'
      'Examples:\n'
      '  somnio skills remove                                     # interactive\n'
      '  somnio skills remove --agent claude --all-skills --global\n'
      '  somnio skills remove --skills flutter-health-audit --force';

  @override
  Future<int> run() async {
    final forceGlobal = argResults!['global'] as bool;
    final forceProject = argResults!['project'] as bool;

    if (forceGlobal && forceProject) {
      _logger.err('Use either --global or --project, not both.');
      return ExitCode.usage.code;
    }

    final agentId = argResults!['agent'] as String?;
    final allSkills = argResults!['all-skills'] as bool;
    final skillsCsv = argResults!['skills'] as String?;
    final force = argResults!['force'] as bool;
    _verbose = argResults!['verbose'] as bool;

    final List<InstallScope> scopes;
    if (forceGlobal) {
      scopes = [InstallScope.global];
    } else if (forceProject) {
      scopes = [InstallScope.project];
    } else if (Prompts.isInteractive) {
      scopes = _promptForScopes();
    } else {
      // No terminal to ask on: consider both rather than guess wrong.
      scopes = [InstallScope.global, InstallScope.project];
    }

    List<AgentConfig> agents;
    if (agentId != null) {
      final agent = AgentRegistry.findById(agentId);
      if (agent == null) {
        _logger.err('Unknown agent: $agentId');
        return ExitCode.usage.code;
      }
      agents = [agent];
    } else {
      agents = AgentRegistry.installableAgents;
    }

    final candidates = _discoverCandidates(agents, scopes);

    if (candidates.isEmpty) {
      _logger.info('No somnio-installed skills found for the selected scope.');
      return ExitCode.success.code;
    }

    final selected = _resolveSelection(candidates, allSkills, skillsCsv);
    if (selected == null) return ExitCode.usage.code;
    if (selected.isEmpty) {
      _logger.info('No skills selected.');
      return ExitCode.success.code;
    }

    if (!force) {
      final confirmed = _logger.confirm(
        'Remove ${selected.length} skill(s)?',
        defaultValue: false,
      );
      if (!confirmed) {
        _logger.info('Cancelled.');
        return ExitCode.success.code;
      }
    }

    _removeAll(selected);

    _logger.info('');
    _logger.success('Removed ${selected.length} skill(s).');
    return ExitCode.success.code;
  }

  /// Finds every skill somnio recorded as installed for [agents] across
  /// [scopes] — see the class doc comment for why manifest membership is
  /// the only thing that makes a skill eligible for removal.
  List<_RemoveCandidate> _discoverCandidates(
    List<AgentConfig> agents,
    List<InstallScope> scopes,
  ) {
    final home = PlatformUtils.homeDirectory;
    final projectRoot = Directory.current.path;
    final candidates = <_RemoveCandidate>[];

    for (final agent in agents) {
      for (final scope in scopes) {
        if (scope == InstallScope.project && !agent.supportsProjectScope) {
          continue;
        }
        final dir = agent.resolvedScopedInstallPath(
          scope: scope,
          home: home,
          projectRoot: projectRoot,
        );
        final manifest = SkillManifest.load(dir);
        for (final entry in manifest.entries) {
          candidates.add((
            agent: agent,
            scope: scope,
            manifest: manifest,
            entry: entry,
          ));
        }
      }
    }

    return candidates;
  }

  /// Resolves which of [candidates] to remove, or `null` on a usage error.
  List<_RemoveCandidate>? _resolveSelection(
    List<_RemoveCandidate> candidates,
    bool allSkills,
    String? skillsCsv,
  ) {
    if (allSkills) {
      return candidates;
    }

    if (skillsCsv != null) {
      final names = skillsCsv
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet();

      final selected = <_RemoveCandidate>[];
      final unknown = <String>[];
      for (final name in names) {
        final matches = candidates.where((c) => c.entry.skill == name);
        if (matches.isEmpty) {
          unknown.add(name);
        } else {
          selected.addAll(matches);
        }
      }

      if (unknown.isNotEmpty) {
        _logger.err('Unknown skill(s): ${unknown.join(', ')}');
        _logger.info('');
        _logger.info('Installed skills:');
        for (final c in candidates) {
          _logger.info('  ${_candidateLabel(c)}');
        }
        return null;
      }

      return selected;
    }

    if (Prompts.isInteractive) {
      final options = candidates.map(_candidateLabel).toList();
      final defaults = List<bool>.filled(options.length, false);
      final indexes = Prompts.selectMany(
        prompt: 'Select skills to remove',
        options: options,
        defaults: defaults,
      );
      return indexes.map((i) => candidates[i]).toList();
    }

    _logger.err('Specify --skills <name> or --all-skills.');
    return null;
  }

  String _candidateLabel(_RemoveCandidate c) =>
      '${c.entry.skill}  —  ${c.agent.displayName} (${_scopeLabel(c.scope)})';

  List<InstallScope> _promptForScopes() {
    final index = Prompts.selectOne(
      prompt: 'Remove from which scope?',
      options: ['global', 'project', 'both'],
    );
    return switch (index) {
      0 => [InstallScope.global],
      1 => [InstallScope.project],
      _ => [InstallScope.global, InstallScope.project],
    };
  }

  /// Deletes every recorded path for each candidate, then updates and
  /// saves that location's manifest exactly once (multiple candidates at
  /// the same (agent, scope) share one loaded [SkillManifest] instance, so
  /// dropped entries accumulate before the single save at the end).
  void _removeAll(List<_RemoveCandidate> selected) {
    final home = PlatformUtils.homeDirectory;
    final projectRoot = Directory.current.path;
    final touchedManifests = <SkillManifest>{};

    for (final candidate in selected) {
      for (final path in candidate.entry.paths) {
        final base = path.root == ManifestRoot.install
            ? candidate.agent.resolvedScopedInstallPath(
                scope: candidate.scope,
                home: home,
                projectRoot: projectRoot,
              )
            : candidate.agent.resolvedScopedExecutionRulesPath(
                scope: candidate.scope,
                home: home,
                projectRoot: projectRoot,
              );
        _deletePath(p.join(base, path.path));
      }
      candidate.manifest.removeEntry(candidate.entry.skill);
      touchedManifests.add(candidate.manifest);
    }

    for (final manifest in touchedManifests) {
      manifest.save();
    }
  }

  /// Deletes whatever is at [path]: a symlink is unlinked without being
  /// followed (skills.sh installs some skill dirs as symlinks; recursing
  /// would destroy the user's source tree), otherwise a directory is
  /// removed recursively or a single file is removed. Mirrors
  /// `AgentInstaller._prune`.
  void _deletePath(String path) {
    final link = Link(path);
    if (link.existsSync()) {
      link.deleteSync();
      if (_verbose) _logger.info('  Removed: $path');
      return;
    }
    final dir = Directory(path);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      if (_verbose) _logger.info('  Removed: $path');
      return;
    }
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
      if (_verbose) _logger.info('  Removed: $path');
    }
  }
}
