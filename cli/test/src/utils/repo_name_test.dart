import 'package:somnio/src/utils/repo_name.dart';
import 'package:test/test.dart';

/// Builds a [GitRunner] that answers each git subcommand from [answers],
/// keyed by its first argument, and `null` for anything else.
GitRunner fakeGit(Map<String, String?> answers) =>
    (args, _) async => answers[args.first];

void main() {
  group('resolveRepoName', () {
    test('prefers the origin remote over the directory name', () async {
      final name = await resolveRepoName(
        '/work/backend',
        git: fakeGit({
          'remote': 'git@github.com:somnio/hoopis-backend.git',
          'rev-parse': '/work/backend/.git',
        }),
      );
      expect(name, 'hoopis-backend');
    });

    test('uses the main checkout when there is no origin', () async {
      // A linked worktree: its directory is named after the branch, but the
      // common dir points at the main checkout.
      final name = await resolveRepoName(
        '/work/hoopis-backend-feat-login/packages/api',
        git: fakeGit({'rev-parse': '/work/hoopis-backend/.git'}),
      );
      expect(name, 'hoopis-backend');
    });

    test('falls back to the directory name outside a git repo', () async {
      final name = await resolveRepoName(
        '/work/some-project',
        git: fakeGit({}),
      );
      expect(name, 'some-project');
    });

    test('skips an origin URL that yields no name', () async {
      final name = await resolveRepoName(
        '/work/backend',
        git: fakeGit({
          'remote': 'https://github.com/.git',
          'rev-parse': '/work/hoopis-backend/.git',
        }),
      );
      expect(name, 'hoopis-backend');
    });
  });
}
