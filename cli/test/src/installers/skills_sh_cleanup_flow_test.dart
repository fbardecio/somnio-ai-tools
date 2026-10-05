import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:somnio/src/installers/skills_sh_cleaner.dart';
import 'package:somnio/src/installers/skills_sh_cleanup_flow.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  late Directory temp;
  late _MockLogger logger;
  late SkillsShCleaner cleaner;
  late String canonical;
  late String link;

  /// Installs one Somnio skill the way `npx skills add -g` does.
  void seedSkillsShInstall() {
    final lockPath = p.join(temp.path, '.agents', '.skill-lock.json');
    Directory(p.dirname(lockPath)).createSync(recursive: true);
    File(lockPath).writeAsStringSync(
      jsonEncode({
        'version': 3,
        'skills': {
          'fha': {'source': somnioSkillsShSource},
        },
      }),
    );
    canonical = p.join(temp.path, '.agents', 'skills', 'fha');
    Directory(canonical).createSync(recursive: true);
    link = p.join(temp.path, '.claude', 'skills', 'fha');
    Directory(p.dirname(link)).createSync(recursive: true);
    Link(link).createSync('../../.agents/skills/fha');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('skills_sh_flow_test_');
    logger = _MockLogger();
    cleaner = SkillsShCleaner(homeDirectory: temp.path, environment: {});
    when(
      () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
    ).thenReturn(true);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('printSkillsShCleanupDryRun', () {
    test('prints every link path when verbose', () {
      seedSkillsShInstall();

      printSkillsShCleanupDryRun(
        logger: logger,
        cleaner: cleaner,
        verbose: true,
      );

      verify(() => logger.info('      $link')).called(1);
    });

    test('removes nothing', () {
      seedSkillsShInstall();

      printSkillsShCleanupDryRun(logger: logger, cleaner: cleaner);

      expect(Directory(canonical).existsSync(), isTrue);
    });

    test('lists skills that would not be reinstalled', () {
      seedSkillsShInstall();

      printSkillsShCleanupDryRun(
        logger: logger,
        cleaner: cleaner,
        reinstalled: const {},
      );

      verify(
        () => logger.warn(any(that: contains('NOT reinstalled'))),
      ).called(1);
    });

    test('ends with the dry-run notice', () {
      printSkillsShCleanupDryRun(logger: logger, cleaner: cleaner);

      verify(
        () => logger.info('Dry run: nothing was removed or installed.'),
      ).called(1);
    });
  });

  group('skillsNotReinstalled', () {
    const plan = SkillsShCleanupPlan(
      lockPath: '/lock',
      skills: [
        SkillsShSkillPlan(
          name: 'Foo',
          aliases: ['foo'],
          canonicalPath: '/c/foo',
          canonicalKind: CanonicalKind.directory,
          links: [],
        ),
        SkillsShSkillPlan(
          name: 'ship',
          canonicalPath: '/c/ship',
          canonicalKind: CanonicalKind.missing,
          links: [],
        ),
      ],
    );

    test('matches reinstalled skills by lock key or folder name', () {
      final names = skillsNotReinstalled(plan, {'foo'}).map((s) => s.name);

      expect(names, ['ship']);
    });
  });

  group('runSkillsShCleanup', () {
    test('returns null without prompting when there is nothing to clean', () {
      final result = runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
      );

      expect(result, isNull);
      verifyNever(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      );
    });

    test('removes the skills after the user confirms', () {
      seedSkillsShInstall();

      final result = runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
      );

      expect(result?.removedSkills, ['fha']);
    });

    test('defaults the prompt to yes when every skill is reinstalled', () {
      seedSkillsShInstall();

      runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
        reinstalled: {'fha'},
      );

      verify(() => logger.confirm(any(), defaultValue: true)).called(1);
    });

    test('defaults the prompt to no when a skill is not reinstalled', () {
      seedSkillsShInstall();

      runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
        reinstalled: const {},
      );

      verify(() => logger.confirm(any(), defaultValue: false)).called(1);
    });

    test('says the removal is global, across all agents', () {
      seedSkillsShInstall();

      runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
      );

      verify(
        () => logger.confirm(
          any(that: contains('globally, from all agents')),
          defaultValue: any(named: 'defaultValue'),
        ),
      ).called(1);
    });

    test('lists skills that are not reinstalled even with assumeYes', () {
      seedSkillsShInstall();

      runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: true,
        interactive: false,
        reinstalled: const {},
      );

      verifyInOrder([
        () => logger.warn(any(that: contains('NOT reinstalled'))),
        () => logger.info('  fha'),
      ]);
    });

    test('keeps everything when the user declines', () {
      seedSkillsShInstall();
      when(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      ).thenReturn(false);

      final result = runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: true,
      );

      expect(result, isNull);
      expect(FileSystemEntity.isLinkSync(link), isTrue);
    });

    test('skips with a warning when non-interactive without --yes', () {
      seedSkillsShInstall();

      final result = runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: false,
        interactive: false,
      );

      expect(result, isNull);
      verify(
        () => logger.warn(any(that: contains('Re-run with --yes'))),
      ).called(1);
    });

    test('removes without prompting when assumeYes is set', () {
      seedSkillsShInstall();

      final result = runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: true,
        interactive: false,
      );

      expect(result?.removedSkills, ['fha']);
      verifyNever(
        () => logger.confirm(any(), defaultValue: any(named: 'defaultValue')),
      );
    });

    test('prints every removed path when verbose', () {
      seedSkillsShInstall();

      runSkillsShCleanup(
        logger: logger,
        cleaner: cleaner,
        assumeYes: true,
        interactive: false,
        verbose: true,
      );

      verifyInOrder([
        () => logger.info('  Removed: $link'),
        () => logger.info('  Removed: $canonical'),
      ]);
    });
  });
}
