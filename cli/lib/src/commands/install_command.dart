import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../agents/agent_config.dart';
import '../agents/agent_registry.dart';
import '../content/content_loader.dart';
import '../content/skill_bundle.dart';
import '../content/skill_registry.dart';
import '../content/workflow_skill.dart';
import '../installers/agent_installer.dart';
import '../utils/command_helpers.dart';
import '../utils/platform_utils.dart';
import '../utils/prompts.dart';

/// Installs skills to a specific agent or all detected agents.
///
/// Usage:
///   somnio install                     # interactive wizard (agents + skills)
///   somnio install --agent claude
///   somnio install --all
///   somnio install --agent claude --skills flutter_health,security_audit
///   somnio install --agent claude --all-skills
class InstallCommand extends Command<int> {
  InstallCommand({required Logger logger}) : _logger = logger {
    argParser
      ..addOption(
        'agent',
        abbr: 'a',
        help: 'Target agent to install to.',
        allowed: AgentRegistry.installableAgents.map((a) => a.id).toList(),
      )
      ..addFlag(
        'all',
        help: 'Install to all detected agents.',
      )
      ..addFlag(
        'all-skills',
        help: 'Install every skill without prompting for a selection.',
      )
      ..addOption(
        'skills',
        help: 'Comma-separated skill ids/names to install (skips the wizard).',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Force reinstall of all skills.',
      );
  }

  final Logger _logger;

  @override
  String get name => 'install';

  @override
  String get description =>
      'Install skills to a specific agent or all detected agents.';

  @override
  Future<int> run() async {
    final force = argResults!['force'] as bool;

    // Resolve repo root / content.
    final ResolvedContent content;
    try {
      content = await CommandHelpers.resolveContent();
    } catch (e) {
      _logger.err('$e');
      return ExitCode.software.code;
    }

    // 1. Resolve which agents to install to.
    final agents = await _resolveAgents();
    if (agents == null) return ExitCode.usage.code;
    if (agents.isEmpty) {
      _logger.info('No agents selected.');
      return ExitCode.success.code;
    }

    // 2. Resolve which skills to install.
    final selection = _resolveSkills();
    if (selection == null) return ExitCode.usage.code;
    if (selection.isEmpty) {
      _logger.info('No skills selected.');
      return ExitCode.success.code;
    }

    // 3. Install the selected skills to each selected agent.
    return _installToAgents(agents, content.loader, selection, force);
  }

  // ──────────────────────────────────────────────────────────────────
  // Agent resolution
  // ──────────────────────────────────────────────────────────────────

  /// Returns the agents to install to, or `null` on a usage error.
  Future<List<AgentConfig>?> _resolveAgents() async {
    final agentId = argResults!['agent'] as String?;
    final installAll = argResults!['all'] as bool;

    if (installAll) {
      return _detectedAgents();
    }

    if (agentId != null) {
      final agent = AgentRegistry.findById(agentId);
      if (agent == null) {
        _logger.err('Unknown agent: $agentId');
        return null;
      }
      return [agent];
    }

    // No flag given: prompt interactively, or error when non-interactive.
    if (!Prompts.isInteractive) {
      _logger.err('Specify --agent <name> or --all.');
      _logger.info('');
      _logger.info('Available agents:');
      for (final agent in AgentRegistry.installableAgents) {
        _logger.info('  ${agent.id.padRight(12)} ${agent.displayName}');
      }
      return null;
    }

    return _promptForAgents();
  }

  /// Detected installable agents (binary present, or IDE agents with no
  /// binary requirement). Mirrors the previous `--all` behavior.
  Future<List<AgentConfig>> _detectedAgents() async {
    final detected = <AgentConfig>[];
    for (final agent in AgentRegistry.installableAgents) {
      if (agent.binary != null) {
        final path = await PlatformUtils.whichBinary(agent.binary!);
        if (path == null) continue;
      }
      detected.add(agent);
    }
    return detected;
  }

  /// Interactive multi-select over all installable agents, pre-selecting
  /// the ones detected on this machine.
  Future<List<AgentConfig>> _promptForAgents() async {
    final agents = AgentRegistry.installableAgents;

    // Pre-compute detection so we can pre-check detected CLI agents.
    final detectedIds = <String>{};
    for (final agent in agents) {
      if (agent.binary == null) continue;
      final path = await PlatformUtils.whichBinary(agent.binary!);
      if (path != null) detectedIds.add(agent.id);
    }

    final options = agents
        .map(
          (a) => detectedIds.contains(a.id)
              ? '${a.displayName} (detected)'
              : a.displayName,
        )
        .toList();
    final defaults =
        agents.map((a) => detectedIds.contains(a.id)).toList();

    final indexes = Prompts.selectMany(
      prompt: 'Select agents to install to',
      options: options,
      defaults: defaults,
    );

    return indexes.map((i) => agents[i]).toList();
  }

  // ──────────────────────────────────────────────────────────────────
  // Skill resolution
  // ──────────────────────────────────────────────────────────────────

  /// Returns the skills to install, or `null` on a usage error.
  _SkillSelection? _resolveSkills() {
    final allSkills = argResults!['all-skills'] as bool;
    final skillsCsv = argResults!['skills'] as String?;

    if (allSkills) {
      return _SkillSelection(
        SkillRegistry.skills,
        SkillRegistry.workflowSkills,
      );
    }

    if (skillsCsv != null) {
      return _parseSkillsCsv(skillsCsv);
    }

    // No flag: prompt interactively, or install everything when there is
    // no terminal (CI, pipes) so the command never hangs on stdin.
    if (!Prompts.isInteractive) {
      return _SkillSelection(
        SkillRegistry.skills,
        SkillRegistry.workflowSkills,
      );
    }

    return _promptForSkills();
  }

  /// Resolves a comma-separated list of skill ids/names against the registry.
  _SkillSelection? _parseSkillsCsv(String csv) {
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

    return _SkillSelection(audit, workflow);
  }

  /// Interactive multi-select over all skills (audit + workflow), all
  /// pre-selected by default.
  _SkillSelection _promptForSkills() {
    final audit = SkillRegistry.skills;
    final workflow = SkillRegistry.workflowSkills;

    final options = <String>[
      ...audit.map((s) => s.displayName),
      ...workflow.map((s) => s.displayName),
    ];
    final defaults = List<bool>.filled(options.length, true);

    final indexes = Prompts.selectMany(
      prompt: 'Select the skills to install',
      options: options,
      defaults: defaults,
    );

    final selectedAudit = <SkillBundle>[];
    final selectedWorkflow = <WorkflowSkill>[];
    for (final i in indexes) {
      if (i < audit.length) {
        selectedAudit.add(audit[i]);
      } else {
        selectedWorkflow.add(workflow[i - audit.length]);
      }
    }

    return _SkillSelection(selectedAudit, selectedWorkflow);
  }

  // ──────────────────────────────────────────────────────────────────
  // Installation
  // ──────────────────────────────────────────────────────────────────

  Future<int> _installToAgents(
    List<AgentConfig> agents,
    ContentLoader loader,
    _SkillSelection selection,
    bool force,
  ) async {
    final single = agents.length == 1;
    var totalSkills = 0;
    var agentCount = 0;
    String? lastLocation;

    for (final agent in agents) {
      final progress = _logger.progress(agent.displayName);

      final installer = AgentInstaller(
        logger: _logger,
        loader: loader,
        agentConfig: agent,
      );

      final result = await installer.install(
        bundles: selection.audit,
        force: force,
      );
      final wfCount = installer.installWorkflowSkills(selection.workflow);
      final agentTotal = result.skillCount + wfCount;

      totalSkills += agentTotal;
      if (agentTotal > 0) agentCount++;
      lastLocation = result.targetDirectory;

      final label = agent.contentLabel;
      final plural = agentTotal == 1 ? label : '${label}s';
      final parts = <String>['$agentTotal $plural'];
      if (result.skippedCount > 0) {
        parts.add('${result.skippedCount} skipped');
      }
      progress.complete('${agent.displayName}  ${parts.join(', ')}');
    }

    _logger.info('');
    if (single && lastLocation != null) {
      _logger.info('Location: $lastLocation');
    } else if (agentCount > 0) {
      _logger.success(
        'Installed $totalSkills skills across $agentCount agents.',
      );
    } else {
      _logger.info('No agents detected. Run "somnio setup" for guided setup.');
    }

    return ExitCode.success.code;
  }
}

/// The skills chosen for installation, split by kind.
class _SkillSelection {
  const _SkillSelection(this.audit, this.workflow);

  final List<SkillBundle> audit;
  final List<WorkflowSkill> workflow;

  bool get isEmpty => audit.isEmpty && workflow.isEmpty;
}
