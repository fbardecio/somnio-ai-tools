# Python Typing Analysis

> Analyze type annotation coverage and correctness — modern generics, union syntax, Protocol usage, pyright strict compliance, and py.typed marker — based on somnio-software standards.

---

STANDARDS SOURCE (local):
- `agent-rules/rules/python/typing.md`

To resolve the absolute path: find the directory containing
`skills/python-best-practices/SKILL.md`, go up two levels to reach
the somnio-ai-tools repository root, then read the file above.

INSTRUCTIONS:
1. USE the `Read` tool to read the local standards file listed above.
2. Proceed with the analysis below using strict adherence to those rules.

ANALYSIS TARGETS:
1. **Type hint coverage**:
   - Verify every function parameter and return type is annotated.
   - Flag unannotated public function signatures.
   - Check module-level and class-level variable annotations (PEP 526).

2. **No bare `Any`**:
   - Flag any use of `Any` without an accompanying suppression comment explaining why a narrower type is not feasible.
   - Flag bare `# type: ignore` without a specific error code.

3. **Modern generic syntax (Python 3.10+)**:
   - Check for deprecated `typing.List`, `typing.Dict`, `typing.Tuple`, `typing.Set` — must be replaced with built-in `list[T]`, `dict[K, V]`, `tuple[T, ...]`, `set[T]`.
   - Check for `Optional[X]` or `Union[X, Y]` — must be replaced with `X | None` or `X | Y`.

4. **Protocol and generics**:
   - Check that structural interfaces use `Protocol` rather than `ABC` where no explicit inheritance is required.
   - Check that generic functions preserving concrete subtypes use bound `TypeVar`.

5. **pyright / mypy strict**:
   - Verify pyright strict mode is configured in `pyproject.toml` or `pyrightconfig.json`.
   - Flag missing return type on `__init__` (`-> None`) or async functions.

6. **`py.typed` marker (PEP 561)**:
   - Check that distributable packages contain an empty `py.typed` file at the package root.

OUTPUT FORMAT:
- **Overview**: Total files analyzed, annotation coverage estimate, compliance score (1-10).
- **Violations**: List specific violations.
  - Format: `path/to/file.py:XX` — [Issue]
- **Compliance**: Highlight well-typed modules or functions found in the codebase.
- **Recommendations**: Specific refactoring suggestions for each violation category.
