// coverage:ignore-file
/// A command bundle — a standalone markdown file under `commands/` installed
/// verbatim as a Claude/Cursor slash command.
///
/// Unlike [WorkflowSkill], command bundles carry no references or asset
/// directories: the root `commands/*.md` files are self-contained (YAML
/// frontmatter + body) and are copied byte-for-byte to the target agent's
/// commands directory, with no per-format transformation.
class CommandBundle {
  const CommandBundle({
    required this.id,
    required this.name,
    required this.displayName,
    required this.description,
    required this.sourceRelativePath,
  });

  /// Internal identifier.
  final String id;

  /// Command name — the source filename without `.md` (e.g. `'ship'`). Also
  /// the installed filename (`<name>.md`) and the resulting slash command.
  final String name;

  /// Human-readable name.
  final String displayName;

  /// Short description shown in the interactive install list.
  final String description;

  /// Path to the command markdown file, relative to the repo root
  /// (e.g. `'commands/ship.md'`).
  final String sourceRelativePath;
}
