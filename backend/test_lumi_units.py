import pytest

from sweatcaster.lumi_units import conversion_reply


@pytest.mark.parametrize(("question", "answer"), [
    ("Hvor mange gram er et halvt kilo?", "0,5 kg = 500 g."),
    ("Hvad er 2,5 kg i gram?", "2,5 kg = 2500 g."),
    ("Lumi, hvor mange gram er 2,5 kilo?", "2,5 kg = 2500 g."),
    ("Og hvor mange gram er der i 2,5 kilo?", "2,5 kg = 2500 g."),
    ("Hvad svarer 2,5 kg til i gram?", "2,5 kg = 2500 g."),
    ("2,5kg i gram, tak!", "2,5 kg = 2500 g."),
    ("Og hvor mange gram er der så i 2,5 kilo?", "2,5 kg = 2500 g."),
    ("Hvor mange gram svarer 2,5 kg til?", "2,5 kg = 2500 g."),
    ("Kan du lige omregne 1,5 liter til dl?", "1,5 l = 15 dl."),
    ("Omregn 1.000 g til kilo", "1000 g = 1 kg."),
    ("Omregn 0.125 kg til g", "0,125 kg = 125 g."),
    ("1 time til minutter", "1 h = 60 min."),
    ("½ tomme i mm", "0,5 in = 12,7 mm."),
    ("-40 grader celsius til fahrenheit", "-40 °C = -40 °F."),
    ("Hvad er 32 °F i °C?", "32 °F = 0 °C."),
    ("Hvor mange gram er der i 2 lb?", "2 lb = 907,18474 g."),
    ("0,000000001 mg i kg", "0,000000001 mg = 0,000000000000001 kg."),
    ("1,123456789 lb i g", "1,123456789 lb = 509,59142751509993 g."),
    ("How many grams are there in two and a half kilos?", "2,5 kg = 2500 g."),
    ("What's 2.500 kg in grams?", "2,5 kg = 2500 g."),
])
def test_danish_answers(question, answer):
    assert conversion_reply(question) == answer


@pytest.mark.parametrize(("question", "answer"), [
    ("Please convert 5 feet to inches", "5 ft = 60 in."),
    ("How many grams in half a kilo?", "0.5 kg = 500 g."),
    ("How many hours are in a day?", "1 d = 24 h."),
    ("0 Celsius to Fahrenheit", "0 °C = 32 °F."),
    ("Convert 1,000 g to kg", "1000 g = 1 kg."),
    ("Hvor mange gram er 1,001 kilo?", "1.001 kg = 1001 g."),
    ("1 second in minutes", "1 s ≈ 0.01666666667 min."),
])
def test_english_answers(question, answer):
    assert conversion_reply(question, language="en-US") == answer


def test_followup_uses_last_conversion_without_copying_model_answers():
    history = [
        {"role": "user", "content": "Hvor mange gram er et halvt kilo?"},
        {"role": "assistant", "content": "Det er 50 gram."},
    ]
    assert conversion_reply("Og 2,5 kg?", history) == "2,5 kg = 2500 g."
    assert conversion_reply("Og hvor meget er 2,5 kilo så?", history) == "2,5 kg = 2500 g."
    assert conversion_reply("Lumi, og 2,5 kilo?", history) == "2,5 kg = 2500 g."
    history.extend([{"role": "user", "content": "Og 2,5 kg?"}, {"role": "assistant", "content": "2500 g."}])
    assert conversion_reply("Og i milligram?", history) == "2,5 kg = 2500000 mg."
    assert conversion_reply("Hvad med 4?", history) == "4 kg = 4000 g."
    assert conversion_reply("Og 2,5 liter?", history) is None
    assert conversion_reply("Og 2 gram?", history) is None
    history.append({"role": "user", "content": "Lad os snakke om filmen."})
    assert conversion_reply("Og 2,5 kg?", history) is None


def test_language_and_history_are_per_call():
    history = [{"role": "user", "content": "Please convert half a foot to inches"}]
    assert conversion_reply("And 2.5?", history, language="en-US") == "2.5 ft = 30 in."
    assert conversion_reply("And 2.5?", [], language="en-US") is None


@pytest.mark.parametrize("message", [
    "Og 2,5 kg?", "Gem at min kat vejer 2,5 kg", "2 kg i gram og lav en indkøbsliste",
    "Hvad koster 2 kg i danske kroner?", "2 kg i ml", "0,5 l i gram", "2 pund til gram",
    "Skriv om 2 kilo i gram", "2 kg i g og mg", "Jeg var ude at løbe i 2 timer",
    "1e300 kg i gram", "1..5 kg i gram", "How many grams in half a kilo of sugar for each person?",
    "Kan man blande 2 kg jord med 3 liter vand?", "20 m/s til km/t", "1 fl oz to g",
])
def test_unrelated_ambiguous_or_composite_messages_reach_normal_chat(message):
    assert conversion_reply(message) is None
