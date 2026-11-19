import json

import pytest

from sweatcaster import film_reasoning as film


CUES = [
    {"start": 10.125, "end": 12.75, "text": "Nora: Don't turn on the light."},
    {"start": 13, "end": 15, "text": "Leo: Why? I can't see anything."},
    {"start": 15.5, "end": 19.25,
     "text": "Nora: The guards outside will notice us if they see light in the window."},
]
CHECK = {"supported": True, "answers_question": True, "danish": True, "unseen_plot": False}


def model(monkeypatch, *responses):
    pending = list(responses)
    calls = []
    def invoke(settings, instruction, content, schema):
        calls.append({"content": content, "schema": schema})
        result = pending.pop(0)
        if isinstance(result, Exception):
            raise result
        return result
    monkeypatch.setattr(film, "_model_json", invoke)
    return calls


def test_danish_why_question_uses_english_meaning_and_preserves_original_evidence(monkeypatch):
    answer = "Fordi vagterne udenfor kan opdage dem, hvis der er lys i vinduet."
    calls = model(monkeypatch, {"answer": answer, "indices": [3]}, CHECK)
    result = film.answer_film(None, "Hvorfor vil Nora have lyset slukket?", CUES, 20)
    assert result == {"answer": answer, "cues": [CUES[2]]}
    assert len(calls) == 2
    assert calls[0]["content"]["completedCues"][2]["text"] == CUES[2]["text"]
    assert calls[1]["content"]["selectedCues"] == [CUES[2]]


def test_spoiler_added_to_an_answer_with_valid_indices_is_not_displayed(monkeypatch):
    spoiler = "Hun vil skjule dem for vagterne, og Leo dør senere i filmen."
    calls = model(monkeypatch, {"answer": spoiler, "indices": [3]},
                  {**CHECK, "supported": False, "unseen_plot": True})
    result = film.answer_film(None, "Hvorfor slukker hun lyset?", CUES, 20)
    assert result == {"answer": film.NO_EVIDENCE, "cues": []}
    assert "Leo dør" not in result["answer"] and len(calls) == 2


@pytest.mark.parametrize("indices", [[0], [4], [-1], [True], [1.0], ["3"], [1, 1], [], [1, 2, 3, 4], None])
def test_only_one_to_three_unique_original_indices_are_accepted(monkeypatch, indices):
    calls = model(monkeypatch, {"answer": "Opdigtet svar", "indices": indices})
    result = film.answer_film(None, "Hvorfor slukker Nora lyset?", CUES, 20)
    assert result["cues"] == [] and "Opdigtet" not in result["answer"] and len(calls) == 1


def test_future_and_unfinished_cues_are_removed_before_either_model_call(monkeypatch):
    future = {"start": 21, "end": 22, "text": "THE FUTURE SECRET"}
    unfinished = {"start": 18, "end": 20.001, "text": "THE UNFINISHED SECRET"}
    calls = model(monkeypatch, {"answer": "Vagterne kan se lyset.", "indices": [3]}, CHECK)
    result = film.answer_film(None, "Hvorfor?", CUES + [future, unfinished], 20)
    assert result["cues"] == [CUES[2]]
    serialized = json.dumps(calls)
    assert "THE FUTURE SECRET" not in serialized and "THE UNFINISHED SECRET" not in serialized


def test_fabricated_quotes_and_metadata_do_not_replace_originals(monkeypatch):
    calls = model(monkeypatch, {"answer": "Svar", "indices": [3],
                               "cues": [{"start": 0, "end": 1, "text": "FABRICATED"}]})
    assert film.answer_film(None, "Hvorfor?", CUES, 20)["cues"] == []
    assert len(calls) == 1
    enriched = [{**cue, "movieTitle": "EXTERNAL PLOT NAME", "plot": "FUTURE DETAIL"} for cue in CUES]
    calls = model(monkeypatch, {"answer": "Vagterne ser lyset.", "indices": [3]}, CHECK)
    result = film.answer_film(None, "Hvorfor?", enriched, 20)
    assert result["cues"] == [CUES[2]]
    assert "EXTERNAL PLOT NAME" not in json.dumps(calls) and "FUTURE DETAIL" not in json.dumps(calls)


@pytest.mark.parametrize("fault", [
    {"supported": False}, {"answers_question": False}, {"unseen_plot": True},
    {"supported": "true"}, {"additional": True},
])
def test_verification_and_language_checks_are_required(monkeypatch, fault):
    model(monkeypatch, {"answer": "A candidate answer.", "indices": [3]},
          {**CHECK, **fault}, {"answer": "Et rettet svar."}, {**CHECK, "danish": False})
    assert film.answer_film(None, "Hvorfor?", CUES, 20) == {"answer": film.NO_EVIDENCE, "cues": []}


def test_supported_answer_can_be_corrected_to_danish_and_must_pass_grounding_again(monkeypatch):
    answer = "Fordi vagterne udenfor kan få øje på lyset."
    calls = model(monkeypatch, {"answer": "Because the guards will see them.", "indices": [3]},
                  {**CHECK, "danish": False}, {"answer": answer}, CHECK)
    assert film.answer_film(None, "Hvorfor slukker Nora lyset?", CUES, 20) == {"answer": answer, "cues": [CUES[2]]}
    assert len(calls) == 4
    assert calls[-1]["content"]["selectedCues"] == [CUES[2]]


def test_language_warning_is_advisory_after_one_rewrite_but_sources_stay_mandatory(monkeypatch):
    answer = "For at hindre vaktmandene i at se lyset."
    calls = model(monkeypatch, {"answer": answer, "indices": [3]},
                  {**CHECK, "danish": False}, {"answer": answer}, {**CHECK, "danish": False})
    assert film.answer_film(None, "Hvorfor?", CUES, 20) == {"answer": answer, "cues": [CUES[2]]}
    assert len(calls) == 4
    calls = model(monkeypatch, {"answer": answer, "indices": [3]},
                  {**CHECK, "danish": False}, {"answer": "Han dør senere."},
                  {**CHECK, "supported": False, "danish": False, "unseen_plot": True})
    assert film.answer_film(None, "Hvorfor?", CUES, 20)["cues"] == []


def test_ambiguous_person_gets_danish_clarification_without_raw_model_text(monkeypatch):
    model(monkeypatch, {"answer": "NEED_NAME", "indices": []})
    assert film.answer_film(None, "Hvor kender han ham fra?", CUES, 20) == {"answer": film.NEED_NAME, "cues": []}


def test_bad_timing_is_never_fed_to_the_model(monkeypatch):
    calls = model(monkeypatch, {"answer": "", "indices": []})
    bad = [{"start": 0, "end": float("nan"), "text": "NAN"},
           {"start": -1, "end": 2, "text": "NEGATIVE"},
           {"start": True, "end": 2, "text": "BOOLEAN"},
           {"start": 0, "end": 10 ** 1000, "text": "OVERFLOW"},
           {"start": 1, "end": 1, "text": "EMPTY"},
           {"start": 1, "end": 2, "text": 2}]
    assert film.answer_film(None, "Hvad skete der?", bad, 20)["cues"] == []
    assert calls == []


def test_model_failure_returns_no_unchecked_partial_answer(monkeypatch):
    model(monkeypatch, {"answer": "Ubekræftet", "indices": [3]}, ValueError("broken JSON"))
    assert film.answer_film(None, "Hvorfor?", CUES, 20) == {"answer": film.MODEL_UNAVAILABLE, "cues": []}


def test_generated_cues_are_chronological_and_exact(monkeypatch):
    calls = model(monkeypatch, {"answer": "Hun advarer ham på grund af vagterne.", "indices": [3, 1]}, CHECK)
    result = film.answer_film(None, "Hvorfor advarer hun ham?", list(reversed(CUES)), 20)
    assert result["cues"] == [CUES[0], CUES[2]]
    assert calls[0]["content"]["completedCues"][0]["index"] == 1
