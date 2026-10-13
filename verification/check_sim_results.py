"""Make command-line simulator runs fail on absent or failing JUnit results."""
from pathlib import Path
from xml.etree import ElementTree


def require_passing_results(path: Path) -> None:
    tree = ElementTree.parse(path)
    cases = list(tree.iter("testcase"))
    failures = list(tree.iter("failure")) + list(tree.iter("error"))
    executed = [case for case in cases if case.find("skipped") is None]
    if not executed or failures:
        raise RuntimeError(f"Simulation failed: {len(executed)} executed tests, "
                           f"{len(failures)} failures/errors; see {path}")
    print(f"Verified {len(executed)} passing simulator tests: {path}")
