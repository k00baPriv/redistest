#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

REPORT_DIR="${ROOT_DIR}/reports"
mkdir -p "$REPORT_DIR"
FAILURES=0
FAILED_STEPS=()

explain_step() {
  local text="$1"
  echo "  -> $text"
}

run_step() {
  local label="$1"
  shift
  echo "$label"
  if ! "$@"; then
    FAILURES=$((FAILURES + 1))
    FAILED_STEPS+=("$label")
    echo "Step failed: $label"
  fi
}

run_info_step() {
  local label="$1"
  shift
  echo "$label"
  if ! "$@"; then
    echo "Step reported issues but is informational: $label"
  fi
}

echo "[0/12] Improve formatting"
explain_step "Applies canonical style so diffs stay clean and linting starts from a normalized codebase."
python -m ruff format .

echo "[1/12] Environment check"
explain_step "Prints the active Python interpreter version to confirm runtime compatibility."
python --version

echo "[2/12] Dependency check (dev tools)"
explain_step "Verifies all QA tools are installed in the current environment."
MISSING=0
for pkg in pytest coverage mypy ruff bandit radon xenon vulture pip-audit; do
  if ! python -m pip show "$pkg" >/dev/null 2>&1; then
    echo "Missing package: $pkg"
    MISSING=1
  fi
done
if [[ "$MISSING" -ne 0 ]]; then
  echo "Install dev dependencies with:"
  echo "  python -m pip install -e '.[dev]'"
  exit 1
fi

echo "[3/12] Unit tests"
explain_step "Checks functional correctness of the code using the project test suite."
run_step "[3/12] Unit tests" python -m pytest tests -q

echo "[4/12] Coverage run"
explain_step "Measures how much production code is exercised by tests and exports machine-readable reports."
run_step "[4/12] Coverage run (test execution)" python -m coverage run -m pytest tests -q
run_step "[4/12] Coverage run (terminal report)" python -m coverage report -m
run_step "[4/12] Coverage run (xml report)" python -m coverage xml -o "$REPORT_DIR/coverage.xml"
run_step "[4/12] Coverage run (html report)" python -m coverage html -d "$REPORT_DIR/htmlcov"

echo "[5/12] Mypy"
explain_step "Performs static type analysis to catch interface and data-flow mismatches before runtime."
run_step "[5/12] Mypy" python -m mypy

echo "[6/12] Ruff lint"
explain_step "Finds lint issues like import order problems, likely bugs, and style violations."
run_step "[6/12] Ruff lint" python -m ruff check .

echo "[7/12] Ruff format check"
explain_step "Verifies formatting is already compliant without mutating files."
run_step "[7/12] Ruff format check" python -m ruff format --check .

echo "[8/12] Bandit security scan"
explain_step "Scans source for insecure coding patterns in the benchmark and setup code."
run_step "[8/12] Bandit security scan" python -m bandit -q -r benchmark_droplet.py redis_api.py do_functions -f txt -o "$REPORT_DIR/bandit.txt"

echo "[9/12] Complexity check (radon cc)"
explain_step "Reports cyclomatic complexity per function/method to identify decision-heavy hotspots."
run_step "[9/12] Complexity check (radon cc)" python -m radon cc -s -a benchmark_droplet.py redis_api.py do_functions

echo "[10/12] Maintainability check (radon mi)"
explain_step "Calculates maintainability index to estimate long-term readability and change cost."
run_step "[10/12] Maintainability check (radon mi)" python -m radon mi -s benchmark_droplet.py redis_api.py do_functions

echo "[11/12] Complexity gate (xenon)"
explain_step "Fails QA if complexity thresholds are exceeded to prevent gradual architecture decay."
run_step "[11/12] Complexity gate (xenon)" python -m xenon --max-absolute B --max-modules B --max-average A benchmark_droplet.py redis_api.py do_functions

echo "[12/12] Dead code and dependency audit"
explain_step "Flags likely unused code and known dependency vulnerabilities."
run_step "[12/12] Dead code check (vulture)" python -m vulture benchmark_droplet.py redis_api.py do_functions tests --min-confidence 80
run_info_step "[12/12] Dependency vulnerability audit (pip-audit)" python -m pip_audit

if [[ "$FAILURES" -eq 0 ]]; then
  echo "QA completed successfully."
else
  echo "QA completed with ${FAILURES} failing step(s)."
  echo "Failed steps:"
  for step in "${FAILED_STEPS[@]}"; do
    echo "  - $step"
  done
  echo "Hint: for Ruff formatting issues run: python -m ruff format ."
  exit 1
fi

echo "Reports:"
echo "  - $REPORT_DIR/coverage.xml"
echo "  - $REPORT_DIR/htmlcov/index.html"
echo "  - $REPORT_DIR/bandit.txt"
