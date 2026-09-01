# Flutter Test Coverage Runner

> Execute Flutter tests and generate comprehensive coverage reports with detailed analysis and recommendations for single app or multi-app monorepos

---

When requested to run tests and generate coverage, you will:

1. Execute Flutter tests with coverage collection (single app or
   per-app for monorepos)
2. Generate detailed coverage reports
3. Analyze coverage results and provide actionable insights
4. Identify areas needing more test coverage
5. Provide recommendations for improving test quality

----------------------------------------------------------------------
MONOREPO DETECTION
----------------------------------------------------------------------

First detect repository structure:
- Single app: app/ directory structure
- Multi-app monorepo: apps/app1/, apps/app2/, etc.
- If apps/ directory exists, analyze each app individually
- If packages/ directory exists, analyze each package individually

----------------------------------------------------------------------
EXECUTION STEPS
----------------------------------------------------------------------

SINGLE APP EXECUTION:
Step 1: Run Tests with Coverage (Single App + Packages)
Execute the following commands in sequence:

IMPORTANT: Pipe all flutter test output through `tail -30` to
capture only the summary. Full verbose test output floods the
context window and is not needed for analysis. The actual coverage
data is captured in lcov.info files on disk, not in stdout.

IMPORTANT: Generated `.g.dart` files (produced by build_runner via
json_serializable, freezed, injectable, etc.) are boilerplate, not
hand-written logic under test. They are trivially "covered" or
"uncovered" as a side effect of running any test that touches the
generated class, which skews the percentage away from the actual
test effort. Every lcov.info file is filtered to strip `.g.dart`
records immediately after it is generated (Step 1b below), before
any DA: line counts are taken for analysis or aggregation.

IMPORTANT: Capture the repo root as an absolute path once, before any
`cd`, and build every `--coverage-path` from that absolute root rather
than a path relative to the current directory. Each package test runs
with `cwd` inside that package's own directory (required for it to
pick up the package's own `pubspec.yaml`/`test/`), so a
repo-root-relative `--coverage-path` resolves to the wrong nested
location (`packages/<name>/coverage/packages/<name>/lcov.info` instead
of `<root>/coverage/packages/<name>/lcov.info`) and the aggregation
step in Step 3 silently reads stale or missing data. Returning with
`cd "$ROOT_DIR"` (absolute) rather than `cd ../..` (relative) also
means one package's failure to return cleanly can never desync the
directory math for every package that runs after it in the loop.

```bash
ROOT_DIR="$(pwd)"

# 1. Run tests in root app directory
echo "Running tests in root app directory"
if command -v fvm &> /dev/null && [ -f ".fvm/fvm_config.json" ]; then
  echo "Using FVM Flutter version"
  fvm flutter test --coverage --reporter=compact \
    --coverage-path="$ROOT_DIR/coverage/app/lcov.info" 2>&1 | tail -30
else
  echo "Using system Flutter version"
  flutter test --coverage --reporter=compact \
    --coverage-path="$ROOT_DIR/coverage/app/lcov.info" 2>&1 | tail -30
fi

# 2. Run tests in all packages (if packages/ exists)
if [ -d "packages/" ]; then
  echo "Running tests in packages directory"
  for package_dir in packages/*/; do
    package_name=$(basename "$package_dir")
    echo "Running tests for package: $package_name"

    cd "$ROOT_DIR/$package_dir"

    if command -v fvm &> /dev/null && [ -f ".fvm/fvm_config.json" ]; then
      fvm flutter test --coverage --reporter=compact \
        --coverage-path="$ROOT_DIR/coverage/packages/$package_name/lcov.info" \
        2>&1 | tail -30
    else
      flutter test --coverage --reporter=compact \
        --coverage-path="$ROOT_DIR/coverage/packages/$package_name/lcov.info" \
        2>&1 | tail -30
    fi

    cd "$ROOT_DIR"
  done
fi
```

Step 1b: Exclude Generated Files from Coverage Data
Strip `.g.dart` records from every lcov.info produced above before
counting any lines. lcov records are contiguous blocks starting at
`SF:<path>` and ending at `end_of_record`; the awk filter drops the
whole block when the `SF:` path ends in `.g.dart`, otherwise passes
it through unchanged:

```bash
echo "Excluding .g.dart files from coverage data"
find coverage/ -name "lcov.info" 2>/dev/null | while read -r lcov_file; do
  awk '/^SF:/{skip=($0 ~ /\.g\.dart$/)} !skip' "$lcov_file" \
    > "$lcov_file.tmp" && mv "$lcov_file.tmp" "$lcov_file"
done
```

MULTI-APP MONOREPO EXECUTION:
Step 1: Run Tests with Coverage (Per App + All Packages)
Execute the following commands in sequence:

IMPORTANT: Same rule as the single-app case — capture the repo root
as an absolute path once, before any `cd`, and build every
`--coverage-path` from that absolute root. Always return with
`cd "$ROOT_DIR"` (absolute), never a relative `cd ../..`, so one
package or app failing to return cleanly can never desync the
directory math — and therefore the coverage-path — for everything
that runs after it in the loop, including across the nested
app→app-packages levels below.

```bash
ROOT_DIR="$(pwd)"

# 1. Run tests for each app in apps/ directory
for app_dir in apps/*/; do
  app_name=$(basename "$app_dir")
  echo "Running tests for app: $app_name"

  cd "$ROOT_DIR/$app_dir"

  # Run tests in app directory
  if command -v fvm &> /dev/null && [ -f ".fvm/fvm_config.json" ]; then
    echo "Using FVM Flutter version for $app_name"
    fvm flutter test --coverage --reporter=compact \
      --coverage-path="$ROOT_DIR/coverage/apps/$app_name/lcov.info" 2>&1 | tail -30
  else
    echo "Using system Flutter version for $app_name"
    flutter test --coverage --reporter=compact \
      --coverage-path="$ROOT_DIR/coverage/apps/$app_name/lcov.info" 2>&1 | tail -30
  fi

  # Run tests in app-specific packages
  # (if apps/<app_name>/packages/ exists)
  if [ -d "packages/" ]; then
    echo "Running tests in app-specific packages for $app_name"
    for package_dir in packages/*/; do
      package_name=$(basename "$package_dir")
      echo "Running tests for app-specific package: $app_name/$package_name"

      cd "$ROOT_DIR/$app_dir$package_dir"

      if command -v fvm &> /dev/null && \
        [ -f ".fvm/fvm_config.json" ]; then
        fvm flutter test --coverage --reporter=compact \
          --coverage-path="$ROOT_DIR/coverage/apps/$app_name/packages/$package_name/lcov.info" \
          2>&1 | tail -30
      else
        flutter test --coverage --reporter=compact \
          --coverage-path="$ROOT_DIR/coverage/apps/$app_name/packages/$package_name/lcov.info" \
          2>&1 | tail -30
      fi

      cd "$ROOT_DIR"
    done
  fi

  cd "$ROOT_DIR"
done

# 2. Run tests in shared packages (if root packages/ exists)
if [ -d "packages/" ]; then
  echo "Running tests in shared packages"
  for package_dir in packages/*/; do
    package_name=$(basename "$package_dir")
    echo "Running tests for shared package: $package_name"

    cd "$ROOT_DIR/$package_dir"

    if command -v fvm &> /dev/null && [ -f ".fvm/fvm_config.json" ]; then
      fvm flutter test --coverage --reporter=compact \
        --coverage-path="$ROOT_DIR/coverage/packages/$package_name/lcov.info" \
        2>&1 | tail -30
    else
      flutter test --coverage --reporter=compact \
        --coverage-path="$ROOT_DIR/coverage/packages/$package_name/lcov.info" \
        2>&1 | tail -30
    fi

    cd "$ROOT_DIR"
  done
fi
```

Step 1b: Exclude Generated Files from Coverage Data
Strip `.g.dart` records from every lcov.info produced above before
counting any lines (same rationale as the single-app case above):

```bash
echo "Excluding .g.dart files from coverage data"
find coverage/ -name "lcov.info" 2>/dev/null | while read -r lcov_file; do
  awk '/^SF:/{skip=($0 ~ /\.g\.dart$/)} !skip' "$lcov_file" \
    > "$lcov_file.tmp" && mv "$lcov_file.tmp" "$lcov_file"
done
```

Step 2: Analyze Coverage Results
After running tests, analyze the coverage data:

SINGLE APP ANALYSIS:
```bash
# Check if coverage directory exists
echo "Coverage files: $(find coverage/ -name '*.info' -o -name '*.json' 2>/dev/null | wc -l)"

# Analyze app coverage
if [ -f "coverage/app/lcov.info" ]; then
  echo "App coverage analysis:"
  grep -E "^DA:|^SF:" coverage/app/lcov.info | head -5 || \
    echo "Coverage file exists"
  grep -c "^DA:" coverage/app/lcov.info || echo "0"
fi

# Analyze packages coverage
if [ -d "coverage/packages/" ]; then
  echo "Packages coverage analysis:"
  for package_coverage in coverage/packages/*/lcov.info; do
    package_name=$(basename $(dirname "$package_coverage"))
    echo "Package $package_name coverage:"
    grep -E "^DA:|^SF:" "$package_coverage" | head -3 || \
      echo "Coverage file exists"
    grep -c "^DA:" "$package_coverage" || echo "0"
  done
fi
```

MULTI-APP ANALYSIS:
```bash
# Analyze coverage for each app
for app_dir in apps/*/; do
  app_name=$(basename "$app_dir")
  echo "Coverage analysis for app: $app_name"
  
  # App coverage
  if [ -f "coverage/apps/$app_name/lcov.info" ]; then
    echo "App $app_name coverage:"
    grep -E "^DA:|^SF:" coverage/apps/$app_name/lcov.info | \
      head -5 || echo "Coverage file exists"
    grep -c "^DA:" coverage/apps/$app_name/lcov.info || echo "0"
  else
    echo "No coverage data found for app $app_name"
  fi
  
  # App-specific packages coverage
  if [ -d "coverage/apps/$app_name/packages/" ]; then
    echo "App-specific packages coverage for $app_name:"
    for package_coverage in \
      coverage/apps/$app_name/packages/*/lcov.info; do
      package_name=$(basename $(dirname "$package_coverage"))
      echo "Package $app_name/$package_name coverage:"
      grep -E "^DA:|^SF:" "$package_coverage" | head -3 || \
        echo "Coverage file exists"
      grep -c "^DA:" "$package_coverage" || echo "0"
    done
  fi
done

# Analyze shared packages coverage
if [ -d "coverage/packages/" ]; then
  echo "Shared packages coverage analysis:"
  for package_coverage in coverage/packages/*/lcov.info; do
    package_name=$(basename $(dirname "$package_coverage"))
    echo "Shared package $package_name coverage:"
    grep -E "^DA:|^SF:" "$package_coverage" | head -3 || \
      echo "Coverage file exists"
    grep -c "^DA:" "$package_coverage" || echo "0"
  done
fi
```


Step 3: Calculate Overall Aggregated Coverage
Calculate the overall coverage percentage by combining all coverage data:

SINGLE APP AGGREGATION:
```bash
# Calculate weighted average coverage
total_lines=0
covered_lines=0

# Add app coverage
if [ -f "coverage/app/lcov.info" ]; then
  app_lines=$(grep -c "^DA:" coverage/app/lcov.info || echo "0")
  app_covered=$(grep "^DA:" coverage/app/lcov.info | \
    grep -c ",[1-9]" || echo "0")
  total_lines=$((total_lines + app_lines))
  covered_lines=$((covered_lines + app_covered))
fi

# Add packages coverage
if [ -d "coverage/packages/" ]; then
  for package_coverage in coverage/packages/*/lcov.info; do
    if [ -f "$package_coverage" ]; then
      package_lines=$(grep -c "^DA:" "$package_coverage" || echo "0")
      package_covered=$(grep "^DA:" "$package_coverage" | \
        grep -c ",[1-9]" || echo "0")
      total_lines=$((total_lines + package_lines))
      covered_lines=$((covered_lines + package_covered))
    fi
  done
fi

# Calculate overall percentage
if [ $total_lines -gt 0 ]; then
  overall_coverage=$((covered_lines * 100 / total_lines))
  echo "Overall aggregated coverage: $overall_coverage%"
else
  echo "Overall aggregated coverage: 0%"
fi

# Per-component coverage breakdown
project_name=$(basename "$(pwd)")
echo "COVERAGE BREAKDOWN:"

if [ -f "coverage/app/lcov.info" ]; then
  bd_lines=$(grep -c "^DA:" coverage/app/lcov.info || echo "0")
  bd_covered=$(grep "^DA:" coverage/app/lcov.info | \
    grep -c ",[1-9]" || echo "0")
  if [ $bd_lines -gt 0 ]; then
    bd_pct=$((bd_covered * 100 / bd_lines))
    echo "  $project_name/lib: $bd_pct%"
  else
    echo "  $project_name/lib: 0%"
  fi
fi

if [ -d "coverage/packages/" ]; then
  for pkg_cov in coverage/packages/*/lcov.info; do
    if [ -f "$pkg_cov" ]; then
      pkg_name=$(basename $(dirname "$pkg_cov"))
      bd_lines=$(grep -c "^DA:" "$pkg_cov" || echo "0")
      bd_covered=$(grep "^DA:" "$pkg_cov" | \
        grep -c ",[1-9]" || echo "0")
      if [ $bd_lines -gt 0 ]; then
        bd_pct=$((bd_covered * 100 / bd_lines))
        echo "  packages/$pkg_name: $bd_pct%"
      else
        echo "  packages/$pkg_name: 0%"
      fi
    fi
  done
fi
```

MULTI-APP AGGREGATION:
```bash
# Calculate weighted average coverage across all apps and packages
total_lines=0
covered_lines=0

# Add apps coverage
for app_dir in apps/*/; do
  app_name=$(basename "$app_dir")
  if [ -f "coverage/apps/$app_name/lcov.info" ]; then
    app_lines=$(grep -c "^DA:" coverage/apps/$app_name/lcov.info || \
      echo "0")
    app_covered=$(grep "^DA:" coverage/apps/$app_name/lcov.info | \
      grep -c ",[1-9]" || echo "0")
    total_lines=$((total_lines + app_lines))
    covered_lines=$((covered_lines + app_covered))
  fi

  # Add app-specific packages coverage
  if [ -d "coverage/apps/$app_name/packages/" ]; then
    for package_coverage in \
      coverage/apps/$app_name/packages/*/lcov.info; do
      if [ -f "$package_coverage" ]; then
        package_lines=$(grep -c "^DA:" "$package_coverage" || echo "0")
        package_covered=$(grep "^DA:" "$package_coverage" | \
          grep -c ",[1-9]" || echo "0")
        total_lines=$((total_lines + package_lines))
        covered_lines=$((covered_lines + package_covered))
      fi
    done
  fi
done

# Add shared packages coverage
if [ -d "coverage/packages/" ]; then
  for package_coverage in coverage/packages/*/lcov.info; do
    if [ -f "$package_coverage" ]; then
      package_lines=$(grep -c "^DA:" "$package_coverage" || echo "0")
      package_covered=$(grep "^DA:" "$package_coverage" | \
        grep -c ",[1-9]" || echo "0")
      total_lines=$((total_lines + package_lines))
      covered_lines=$((covered_lines + package_covered))
    fi
  done
fi

# Calculate overall percentage
if [ $total_lines -gt 0 ]; then
  overall_coverage=$((covered_lines * 100 / total_lines))
  echo "Overall aggregated coverage: $overall_coverage%"
else
  echo "Overall aggregated coverage: 0%"
fi

# Per-component coverage breakdown
echo "COVERAGE BREAKDOWN:"

for app_dir in apps/*/; do
  app_name=$(basename "$app_dir")

  # App lib coverage
  if [ -f "coverage/apps/$app_name/lcov.info" ]; then
    bd_lines=$(grep -c "^DA:" coverage/apps/$app_name/lcov.info || \
      echo "0")
    bd_covered=$(grep "^DA:" coverage/apps/$app_name/lcov.info | \
      grep -c ",[1-9]" || echo "0")
    if [ $bd_lines -gt 0 ]; then
      bd_pct=$((bd_covered * 100 / bd_lines))
      echo "  $app_name/lib: $bd_pct%"
    else
      echo "  $app_name/lib: 0%"
    fi
  fi

  # App-specific packages coverage
  if [ -d "coverage/apps/$app_name/packages/" ]; then
    for pkg_cov in coverage/apps/$app_name/packages/*/lcov.info; do
      if [ -f "$pkg_cov" ]; then
        pkg_name=$(basename $(dirname "$pkg_cov"))
        bd_lines=$(grep -c "^DA:" "$pkg_cov" || echo "0")
        bd_covered=$(grep "^DA:" "$pkg_cov" | \
          grep -c ",[1-9]" || echo "0")
        if [ $bd_lines -gt 0 ]; then
          bd_pct=$((bd_covered * 100 / bd_lines))
          echo "  $app_name/packages/$pkg_name: $bd_pct%"
        else
          echo "  $app_name/packages/$pkg_name: 0%"
        fi
      fi
    done
  fi
done

# Shared packages coverage
if [ -d "coverage/packages/" ]; then
  for pkg_cov in coverage/packages/*/lcov.info; do
    if [ -f "$pkg_cov" ]; then
      pkg_name=$(basename $(dirname "$pkg_cov"))
      bd_lines=$(grep -c "^DA:" "$pkg_cov" || echo "0")
      bd_covered=$(grep "^DA:" "$pkg_cov" | \
        grep -c ",[1-9]" || echo "0")
      if [ $bd_lines -gt 0 ]; then
        bd_pct=$((bd_covered * 100 / bd_lines))
        echo "  packages/$pkg_name: $bd_pct%"
      else
        echo "  packages/$pkg_name: 0%"
      fi
    fi
  done
fi
```

Step 4: Generate Coverage Summary
Create a comprehensive coverage analysis including:

MANDATORY: Your final output MUST include a "Code Coverage:" line that the
report generator will extract. Place it prominently (e.g., at the start of
COVERAGE OVERVIEW).

SINGLE APP SUMMARY:
- Code Coverage: [X]% (overall: lib + packages) — MANDATORY
- Coverage Breakdown: — MANDATORY (one line per component)
  [ProjectName]/lib: [X]%
  packages/[package_name]: [X]%
  (list every package found)
- App test count and coverage percentage
- Packages test counts and coverage percentages (if packages/ exists)
- Overall aggregated coverage percentage
  (weighted average of app + packages)
- Files with low coverage (< 70%) in app and packages
- Files with no coverage in app and packages
- Test execution time for app and packages
- Failed tests (if any) in app and packages

MULTI-APP SUMMARY:
- Code Coverage: App [name]: [X]%, App [name2]: [Y]% — MANDATORY
- Coverage Breakdown: — MANDATORY (one line per component)
  [AppName1]/lib: [X]%
  [AppName1]/packages/[package_name]: [X]%
  packages/[shared_package_name]: [X]%
  [AppName2]/lib: [X]%
  [AppName2]/packages/[package_name]: [X]%
  (list every app, app-package, and shared package found)
- Per-app test counts and coverage percentages
- Per-app packages test counts and coverage percentages
- Shared packages test counts and coverage percentages
- Overall monorepo coverage aggregation
  (weighted average of all apps and packages)
- Cross-app coverage consistency analysis
- Cross-package coverage consistency analysis
- Files with low coverage per app and package
- Files with no coverage per app and package
- Test execution times per app and package
- Failed tests per app and package

----------------------------------------------------------------------
COVERAGE ANALYSIS FRAMEWORK
----------------------------------------------------------------------

Coverage Categories:
- Excellent: 90-100%
- Good: 80-89%
- Fair: 70-79%
- Poor: 60-69%
- Critical: < 60%

File Analysis:
- Core business logic files (lib/models/, lib/repositories/, lib/bloc/)
- UI components (lib/widgets/, lib/pages/)
- Utility functions (lib/utils/, lib/helpers/)
- API services (lib/services/, lib/api/)

Test Quality Indicators:
- Unit tests vs Integration tests ratio
- Mock usage for external dependencies
- Test isolation and independence
- Assertion quality and coverage

----------------------------------------------------------------------
OUTPUT FORMAT
----------------------------------------------------------------------

Provide the following structured output:

1. EXECUTION SUMMARY
   - Repository structure type (single app / multi-app monorepo)
   - Test execution status (per app and package if applicable)
   - Total tests run (per app and package if applicable)
   - Passed/Failed/Skipped counts (per app and package if applicable)
   - Execution time (per app and package if applicable)
   - Flutter version used for execution

2. COVERAGE OVERVIEW
   MANDATORY: Include exactly one line at the start of COVERAGE OVERVIEW:
   - Single app: Code Coverage: [X]% (overall: lib + packages)
   - Multi-app monorepo: Code Coverage: App [name]: [X]%, App
     [name2]: [Y]% (per-app overall including lib + app packages +
     shared packages)
   MANDATORY: Include per-component "Coverage Breakdown:" immediately
   after "Code Coverage:". One line per component:
   - Single app:
     Coverage Breakdown:
       [ProjectName]/lib: [X]%
       packages/[package_name]: [X]%
   - Multi-app monorepo:
     Coverage Breakdown:
       [AppName1]/lib: [X]%
       [AppName1]/packages/[package_name]: [X]%
       packages/[shared_package_name]: [X]%
       [AppName2]/lib: [X]%
       [AppName2]/packages/[package_name]: [X]%
   - App coverage percentage (per app if multi-app)
   - Packages coverage percentage (per package if applicable)
   - Overall aggregated coverage percentage
     (weighted average of all components)
   - Total lines of code (per app and package if applicable)
   - Lines covered (per app and package if applicable)
   - Lines missed (per app and package if applicable)
   - Cross-app coverage comparison (if multi-app)
   - Cross-package coverage comparison (if packages exist)

3. DETAILED COVERAGE BREAKDOWN
   - Coverage by file category (per app and package if applicable)
   - Top 10 files with lowest coverage (per app and package if applicable)
   - Files with 0% coverage (per app and package if applicable)
   - Critical files needing attention (per app and package if applicable)

4. TEST QUALITY ASSESSMENT
   - Test distribution analysis (per app and package if applicable)
   - Mock usage evaluation (per app and package if applicable)
   - Test isolation assessment (per app and package if applicable)
   - Performance considerations (per app and package if applicable)

5. RECOMMENDATIONS
   - Priority files for test coverage improvement
     (per app and package if applicable)
   - Specific testing strategies (per app and package if applicable)
   - Test architecture suggestions (per app and package if applicable)
   - CI/CD integration recommendations (per app and package if applicable)
   - Flutter version management best practices
   - Cross-app testing consistency (if multi-app)
   - Cross-package testing consistency (if packages exist)

6. ACTION ITEMS
   - Immediate actions (high priority) (per app and package if applicable)
   - Medium-term improvements (per app and package if applicable)
   - Long-term testing strategy (per app and package if applicable)
   - FVM setup and version alignment
   - Multi-app coordination improvements (if multi-app)
   - Package testing coordination improvements (if packages exist)

----------------------------------------------------------------------
COMMAND EXECUTION RULES
----------------------------------------------------------------------

SINGLE APP EXECUTION:
Always execute commands in this order (`ROOT_DIR="$(pwd)"` captured
before step 1, every `--coverage-path` and every return `cd` built
from it — see the ROOT_DIR rationale above; a repo-root-relative
`--coverage-path` issued from inside a package directory resolves to
the wrong nested location):
1. flutter test --coverage --reporter=compact \
   --coverage-path="$ROOT_DIR/coverage/app/lcov.info"
   (or fvm flutter test --coverage --reporter=compact if FVM is
   configured)
2. For each package in packages/: cd "$ROOT_DIR/packages/<package_name>" \
   && flutter test --coverage --reporter=compact \
   --coverage-path="$ROOT_DIR/coverage/packages/<package_name>/lcov.info" \
   && cd "$ROOT_DIR"
3. Analysis commands for coverage data (app + packages)

MULTI-APP EXECUTION:
Always execute commands in this order (same `ROOT_DIR` rule as above):
1. For each app: cd "$ROOT_DIR/apps/<app_name>" && flutter test --coverage \
   --reporter=compact \
   --coverage-path="$ROOT_DIR/coverage/apps/<app_name>/lcov.info" \
   && cd "$ROOT_DIR"
2. For each app-specific package: \
   cd "$ROOT_DIR/apps/<app_name>/packages/<package_name>" && \
   flutter test --coverage --reporter=compact \
   --coverage-path="$ROOT_DIR/coverage/apps/<app_name>/packages/<package_name>/lcov.info" \
   && cd "$ROOT_DIR"
3. For each shared package: cd "$ROOT_DIR/packages/<package_name>" && \
   flutter test --coverage --reporter=compact \
   --coverage-path="$ROOT_DIR/coverage/packages/<package_name>/lcov.info" \
   && cd "$ROOT_DIR"
4. Analysis commands for coverage data per app and package
5. Cross-app and cross-package analysis and aggregation

Handle errors gracefully:
- If tests fail, provide detailed error analysis
  (per app and package if applicable)
- If coverage generation fails, troubleshoot step by step
  (per app and package if applicable)
- Always provide actionable next steps
  (per app and package if applicable)

----------------------------------------------------------------------
COVERAGE THRESHOLDS
----------------------------------------------------------------------

Recommended Coverage Targets:
- Overall project: 70%+ (per app and package if applicable)
- Business logic: 80%+ (per app and package if applicable)
- UI components: 60%+ (per app and package if applicable)
- Utilities: 75%+ (per app and package if applicable)
- API services: 70%+ (per app and package if applicable)
- Shared packages: 80%+ (higher threshold due to reusability)

Critical Files (must have > 80% coverage):
- Authentication logic (per app and package if applicable)
- Payment processing (per app and package if applicable)
- Data validation (per app and package if applicable)
- Security-related functions (per app and package if applicable)
- Core business rules (per app and package if applicable)
- Package public APIs (per package if applicable)

----------------------------------------------------------------------
INTEGRATION WITH CI/CD
----------------------------------------------------------------------

Provide recommendations for:
- Coverage thresholds in CI (per app and package if applicable)
- Automated coverage reporting (per app and package if applicable)
- Coverage badge generation (per app and package if applicable)
- PR coverage requirements (per app and package if applicable)
- Coverage trend tracking (per app and package if applicable)
- Multi-app CI/CD coordination (if multi-app)
- Package testing coordination (if packages exist)
- Cross-package dependency testing strategies

Remember: Focus on actionable insights and specific recommendations
for improving test coverage and quality, considering single app,
multi-app, and package scenarios.

----------------------------------------------------------------------
ARTIFACT PERSISTENCE (MANDATORY)
----------------------------------------------------------------------

After completing ALL coverage analysis, you MUST save the coverage
summary to a persistent artifact file. This is NON-NEGOTIABLE because
the report generator depends on this file to extract coverage data.

Write the coverage summary to the exact path your invoker gave you:

- Via `somnio run`: the step prompt names the path ("Save your
  complete findings to: ..."). Use it verbatim.
- Via in-session dispatch: use the path in this skill's Dispatch Table
  in SKILL.md.

Create the parent directory first (`mkdir -p` on the artifact file's
directory). Never invent, shorten, or re-derive the path.

The artifact file MUST contain AT MINIMUM these two mandatory sections
at the very top of the file, before any other content:

SINGLE APP FORMAT:
```
Code Coverage: [X]% (overall: lib + packages)
Coverage Breakdown:
  [ProjectName]/lib: [X]%
  packages/[package_name]: [X]%
  packages/[package_name]: [X]%
  ... (one line per package)
```

MULTI-APP FORMAT:
```
Code Coverage: App [name]: [X]%, App [name2]: [Y]%
Coverage Breakdown:
  [AppName1]/lib: [X]%
  [AppName1]/packages/[package_name]: [X]%
  packages/[shared_package_name]: [X]%
  [AppName2]/lib: [X]%
  ... (one line per app/package)
```

If coverage could not be calculated (e.g., no tests, no lcov.info),
write:
```
Code Coverage: 0% (no coverage data available)
Coverage Breakdown:
  (no coverage data — tests failed or no test files found)
```

NEVER omit this artifact. The report generator will fail to produce
correct Section 7 (Testing) without it.
