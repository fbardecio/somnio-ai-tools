// coverage:ignore-file
import 'dart:io';

import 'package:path/path.dart' as p;

import '../agents/agent_config.dart';
import '../agents/agent_registry.dart';
import 'platform_utils.dart';

/// Information about a detected agent.
class AgentInfo {
  const AgentInfo({required this.installed, this.path, this.version});

  final bool installed;
  final String? path;
  final String? version;

  @override
  String toString() => installed
      ? 'AgentInfo(installed, path: $path)'
      : 'AgentInfo(not installed)';
}

/// Detects which AI coding agents are installed on the system.
///
/// All detection is driven by [AgentRegistry] — adding a new agent there
/// automatically makes it discoverable here.
class AgentDetector {
  /// Whether [path] is a directory holding at least one entry besides
  /// macOS `.DS_Store` metadata.
  static bool hasContent(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return false;
    try {
      return dir
          .listSync(followLinks: false)
          .any((entity) => p.basename(entity.path) != '.DS_Store');
    } on FileSystemException {
      return false;
    }
  }

  /// Detects all agents that have a binary (CLI agents).
  Future<Map<AgentConfig, AgentInfo>> detect() async {
    final results = <AgentConfig, AgentInfo>{};
    for (final agent in AgentRegistry.agents) {
      results[agent] = await _detectAgent(agent);
    }
    return results;
  }

  /// Detects a single agent by checking its binary, detection binaries,
  /// and detection paths.
  Future<AgentInfo> _detectAgent(AgentConfig agent) async {
    // Check primary binary on PATH
    if (agent.binary != null) {
      final binPath = await PlatformUtils.whichBinary(agent.binary!);
      if (binPath != null) {
        return AgentInfo(installed: true, path: binPath);
      }
    }

    // Check additional detection binaries
    for (final bin in agent.detectionBinaries) {
      final binPath = await PlatformUtils.whichBinary(bin);
      if (binPath != null) {
        return AgentInfo(installed: true, path: binPath);
      }
    }

    // Check detection paths (app bundles, etc.)
    for (final detPath in agent.detectionPaths) {
      if (Directory(detPath).existsSync() || File(detPath).existsSync()) {
        return AgentInfo(installed: true, path: detPath);
      }
    }

    // Check for a populated install directory (installed but binary not in
    // PATH). An empty one does not count: skills.sh creates `<agent>/skills`
    // folders for agents the user may never have installed.
    if (agent.installScope == InstallScope.global) {
      final home = PlatformUtils.homeDirectory;
      final installDir = agent.resolvedInstallPath(home: home);
      if (hasContent(installDir)) {
        return AgentInfo(installed: true, path: installDir);
      }
    }

    return const AgentInfo(installed: false);
  }
}