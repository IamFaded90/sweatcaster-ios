import pytest

from sweatcaster.crew_proposals import crew_generator, validate_candidate


class LocalFlow:
    """Minimal test dispatcher: production always imports CrewAI unless explicitly injected."""
    def __init__(self, **kwargs):
        pass

    def kickoff(self):
        return self.review(self.draft())


def start():
    return lambda function: function


def listen(_):
    return lambda function: function


def proposal(value=2):
    return {"feasible": True, "files": {"a.py": f"answer = {value}\n"}, "tests": ["Check the returned answer."]}


def test_review_receives_original_and_draft_without_writing_files():
    calls = []
    def generate(goal, files, context):
        calls.append((goal, files, context))
        return proposal(len(calls) + 1)
    run = crew_generator(generate, (LocalFlow, listen, start))
    result = run("Improve", {"a.py": "answer = 1\n"})
    assert result["files"]["a.py"] == "answer = 3\n"
    assert calls[1][1] == {"a.py": "answer = 1\n"}
    assert calls[1][2]["proposed_change"] == proposal(2)


def test_declined_draft_does_not_spend_second_model_call():
    calls = []
    def generate(*args):
        calls.append(args)
        return {"feasible": False, "reason": "Missing context"}
    result = crew_generator(generate, (LocalFlow, listen, start))("Help", {"a.py": "x = 1"})
    assert not result["feasible"] and len(calls) == 1


def test_unapproved_path_and_invalid_python_stop_before_review():
    candidate = proposal()
    candidate["files"] = {"other.py": "x = 1"}
    with pytest.raises(ValueError):
        validate_candidate(candidate, {"a.py"})
    candidate["files"] = {"a.py": "def broken("}
    with pytest.raises(SyntaxError):
        validate_candidate(candidate, {"a.py"})


def test_second_job_gets_no_first_job_context():
    seen = []
    def generate(goal, files, context):
        seen.append(context)
        return proposal()
    run = crew_generator(generate, (LocalFlow, listen, start))
    run("One", {"a.py": "x = 1"}, {"note": "First"})
    run("Two", {"a.py": "x = 1"}, {"note": "Second"})
    assert seen[2] == {"note": "Second"}
    assert seen[3]["local_context"] == {"note": "Second"}
