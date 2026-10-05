import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import 'skills_sh_cleaner.dart';

/// The planned skills that the calling command will not install again
/// afterwards, given the skill names it does install ([reinstalled]).
///
/// A planned skill counts as reinstalled when any of its lock keys, or its
/// folder name, is in [reinstalled].
List<SkillsShSkillPlan> skillsNotReinstalled(
  SkillsShCleanupPlan plan,
  Set<String> reinstalled,
) =>
    [
      for (final skill in plan.skills)
        if (!reinstalled.contains(p.basename(skill.canonicalPath)) &&
            !skill.lockKeys.any(reinstalled.contains))
          skill,
    ];

/// Prints the skills.sh cleanup plan for `--dry-run` without changing
/// anything.
///
/// Lists each Somnio skill with its canonical copy and link count; with
/// [verbose], every link path too. When [reinstalled] is given, the skills
/// outside it are listed as removed and not reinstalled.
void printSkillsShCleanupDryRun({
  required Logger logger,
  required SkillsShCleaner cleaner,
  bool verbose = false,
  Set<String>? reinstalled,
}) {
  final plan = cleaner.plan();
  plan.warnings.forEach(logger.warn);
  plan.describe(verbose: verbose).forEach(logger.info);
  if (reinstalled != null) {
    _warnNotReinstalled(logger, skillsNotReinstalled(plan, reinstalled));
  }
  logger
    ..info('')
    ..info('Dry run: nothing was removed or installed.');
}

/// Removes Somnio skills installed by skills.sh after showing the plan and
/// asking for confirmation.
///
/// The removal is global: it covers every agent, whatever the calling
/// command installs. When [reinstalled] is given (the skill names the caller
/// installs afterwards), planned skills outside it are listed as "will be
/// removed and NOT reinstalled" — even with [assumeYes] — and the prompt then
/// defaults to no.
///
/// With [assumeYes] the prompt is skipped. Without it, a non-[interactive]
/// session skips the cleanup with a warning instead of hanging on stdin, as
/// does a declined prompt; the caller then carries on with its install or
/// update either way. The confirmed plan is what gets applied (see
/// [SkillsShCleaner.apply]). With [verbose], every link path is listed and
/// every removed path echoed.
///
/// Returns the cleanup result, or `null` when nothing was removed because
/// there was nothing to do or the cleanup was skipped.
SkillsShCleanupResult? runSkillsShCleanup({
  required Logger logger,
  required SkillsShCleaner cleaner,
  required bool assumeYes,
  required bool interactive,
  bool verbose = false,
  Set<String>? reinstalled,
}) {
  final plan = cleaner.plan();
  plan.warnings.forEach(logger.warn);
  if (plan.isEmpty) return null;

  logger.info('');
  plan.describe(verbose: verbose).forEach(logger.info);
  logger
    ..info('')
    ..info(
      'These copies are not tracked by Somnio, so "somnio skills update" '
      'never refreshes them.',
    );
  final notReinstalled = reinstalled == null
      ? const <SkillsShSkillPlan>[]
      : skillsNotReinstalled(plan, reinstalled);
  _warnNotReinstalled(logger, notReinstalled);
  logger.info('');

  final count = plan.skills.length;
  if (!assumeYes) {
    if (!interactive) {
      logger.warn(
        'Skipped skills.sh cleanup: no terminal to confirm on. '
        'Re-run with --yes to remove them.',
      );
      return null;
    }
    final confirmed = logger.confirm(
      'Remove these $count Somnio skill(s) installed by skills.sh — '
      'globally, from all agents?',
      defaultValue: notReinstalled.isEmpty,
    );
    if (!confirmed) {
      logger.warn('Skipped skills.sh cleanup; nothing was removed.');
      return null;
    }
  }

  final result = cleaner.apply(plan);
  if (verbose) {
    for (final path in [...result.unlinkedLinks, ...result.deletedCanonicals]) {
      logger.info('  Removed: $path');
    }
  }
  result.warnings.forEach(logger.warn);
  final copies = result.deletedCanonicals.length;
  logger
    ..success(
      'Removed ${result.removedSkills.length} Somnio skill(s) installed by '
      'skills.sh (${result.unlinkedLinks.length} link(s), $copies canonical '
      '${copies == 1 ? 'copy' : 'copies'}).',
    )
    ..info('');
  return result;
}

void _warnNotReinstalled(Logger logger, List<SkillsShSkillPlan> skills) {
  if (skills.isEmpty) return;
  logger.warn(
    '${skills.length} of these will be removed and NOT reinstalled by this '
    'command:',
  );
  for (final skill in skills) {
    logger.info('  ${skill.name}');
  }
}
