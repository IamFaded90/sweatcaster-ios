"""Exercise the real CrewAI dispatcher using simulated model replies; never apply a proposal."""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("crew_proposals", Path(__file__).parent / "sweatcaster/crew_proposals.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def main():
    isolated = len(sys.argv) > 1

    def dispatch(generate):
        if isolated:
            return module.isolated_crew_generator(generate, sys.argv[1])
        return module.crew_generator(generate)

    calls = []

    def generate(goal, files, context):
        calls.append(context)
        return {"feasible": True, "files": {"a.py": "answer = 2\n"}, "tests": ["Check answer equals 2."]}

    run = dispatch(generate)
    result = run("Improve", {"a.py": "answer = 1\n"})
    assert result["files"]["a.py"] == "answer = 2\n" and len(calls) == 2

    class Busy(Exception):
        pass

    def unavailable(*_):
        raise Busy()

    try:
        dispatch(unavailable)("Improve", {"a.py": "answer = 1\n"})
    except Busy:
        pass
    else:
        raise AssertionError("Busy model must propagate so CodeBatch can requeue the job")

    def invalid(*_):
        return {"feasible": True, "files": {"outside.py": "x=1"}, "tests": ["Check"]}

    try:
        dispatch(invalid)("Improve", {"a.py": "answer = 1\n"})
    except (ValueError, RuntimeError):
        pass
    else:
        raise AssertionError("The real dispatcher must propagate invalid proposal failures")
    print("CrewAI: draft, review, busy propagation and unapproved-path rejection passed. Models mocked; nothing applied.")


if __name__ == "__main__":
    main()
