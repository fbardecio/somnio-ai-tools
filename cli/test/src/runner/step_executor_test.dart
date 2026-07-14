import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:somnio/src/agents/agent_config.dart';
import 'package:somnio/src/runner/run_config.dart';
import 'package:somnio/src/runner/step_executor.dart';
import 'package:test/test.dart';

void main() {
  group('StepExecutor.execute', () {
    late Directory tempDir;
    late RunConfig config;

    const step = ExecutionStep(index: 4, ruleName: 'test-coverage');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('step_executor_test');
      final ruleBasePath = p.join(tempDir.path, 'references');
      Directory(ruleBasePath).createSync(recursive: true);
      File(p.join(ruleBasePath, 'test-coverage.md'))
          .writeAsStringSync('# rule');

      config = RunConfig(
        bundleId: 'python_health',
        bundleName: 'python-health-audit',
        displayName: 'Python Project Health Audit',
        techPrefix: 'python',
        agentConfig: const AgentConfig(
          id: 'fake-agent',
          displayName: 'Fake Agent',
          binary: 'fake-agent',
          canExecute: true,
          installPath: '/tmp/somnio-fake-agent',
        ),
        steps: const [step],
        ruleBasePath: ruleBasePath,
        templatePath: p.join(tempDir.path, 'template.md'),
        artifactsDir: p.join(tempDir.path, 'reports', '.artifacts'),
        reportPath: p.join(tempDir.path, 'reports', 'audit.md'),
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test(
        'exports SOMNIO_ARTIFACT_FILE with the step artifact path '
        'to the spawned AI CLI process', () async {
      Map<String, String>? capturedEnvironment;

      final executor = StepExecutor(
        config: config,
        logger: Logger(level: Level.quiet),
        processRunner: (executable, args,
            {workingDirectory, environment}) async {
          capturedEnvironment = environment;
          return ProcessResult(0, 0, '', '');
        },
      );

      await executor.execute(step);

      final expectedArtifactPath =
          p.join(config.artifactsDir, 'step_04_test-coverage.md');
      expect(
        capturedEnvironment?['SOMNIO_ARTIFACT_FILE'],
        expectedArtifactPath,
      );
    });
  });
}
