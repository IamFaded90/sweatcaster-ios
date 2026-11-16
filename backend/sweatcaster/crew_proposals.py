"""CrewAI Flow for local code proposals. The existing CodeBatch owns approval and persistence.

No tools, shell, credentials, cloud LLM or CrewAI memory backend are exposed to this flow.
Ollama requests retain FadedAI's existing model lease, loopback and timeout checks.
"""

from __future__ import annotations

import json
import os


def validate_candidate(candidate, allowed: set[str]) -> dict:
    if not isinstance(candidate, dict) or type(candidate.get("feasible")) is not bool:
        raise ValueError("Ugyldigt forslag fra holdet.")
    if not candidate["feasible"]:
        return {"feasible": False, "reason": str(candidate.get("reason", "Opgaven kræver mere kontekst."))[:600]}
    files, tests = candidate.get("files"), candidate.get("tests")
    if not isinstance(files, dict) or not files or not files.keys() <= allowed:
        raise ValueError("Holdet foreslog filer uden for opgaven.")
    if not isinstance(tests, list) or not 1 <= len(tests) <= 6 or not all(
        isinstance(test, str) and 1 <= len(test.strip()) <= 300 for test in tests
    ):
        raise ValueError("Forslaget mangler en konkret testplan.")
    for path, source in files.items():
        if not isinstance(source, str) or not source.strip() or len(source) > 16_000 or "\x00" in source:
            raise ValueError("Forslaget indeholder en ugyldig fil.")
        if path.endswith(".py"):
            compile(source, path, "exec")
        elif path.endswith(".json"):
            json.loads(source)
    return candidate


def crew_generator(generate, flow_types=None):
    # Set before importing CrewAI so local proposals are not sent as tracing data.
    os.environ["OTEL_SDK_DISABLED"] = "true"
    os.environ["CREWAI_TELEMETRY_DISABLED"] = "true"
    if flow_types is None:
        from crewai.flow.flow import Flow, listen, start
    else:
        Flow, listen, start = flow_types

    def run(goal, files, context=None):
        if not isinstance(files, dict) or not 1 <= len(files) <= 5:
            raise ValueError("Vælg 1–5 kildefiler.")
        if sum(len(source) for source in files.values()) > 6000:
            raise ValueError("Opgaven er for stor til lokal holdgennemgang.")
        allowed = set(files)

        class ProposalFlow(Flow):
            @start()
            def draft(self):
                return validate_candidate(generate(goal, dict(files), context), allowed)

            @listen(draft)
            def review(self, candidate):
                if not candidate["feasible"]:
                    return candidate
                # The reviewer sees originals and the draft. It may decline or revise the proposal.
                review_context = {
                    "local_context": context,
                    "proposed_change": candidate,
                    "instruction": "Review the draft against the original source and goal. Correct errors. "
                                   "Return the same proposal JSON format. Do not claim tests were run.",
                }
                if len(json.dumps(review_context, ensure_ascii=False)) > 28_000:
                    raise ValueError("Forslaget er for stort til endnu en lokal gennemgang.")
                return validate_candidate(generate(goal, dict(files), review_context), allowed)

        # A new instance per job; never share private state between bots or repositories.
        return ProposalFlow(tracing=False, suppress_flow_events=True).kickoff()

    return run
