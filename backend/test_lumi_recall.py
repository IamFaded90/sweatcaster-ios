import pytest

from sweatcaster.lumi_recall import recall_reply


def user(text):
    return {"role": "user", "content": text}


def assistant(text):
    return {"role": "assistant", "content": text}


def test_recall_preserves_exact_value_after_topic_change():
    turns = [user("Min cykel er petrolblå."), assistant("Blå er flot!"),
             user("Hvilken farve har en citron?"), assistant("Gul. Din cykel må være gul.")]
    for q in ["Hvilken farve sagde jeg, at min cykel var?", "Hvilken farve er min cykel?",
              "Lumi, kan du huske farven på min cykel igen?"]:
        assert recall_reply(q, turns, "da-DK") == "Du skrev »petrolblå«."
    assert recall_reply("What color did I say my bicycle was?", turns, "en-US") == "You wrote “petrolblå”."


@pytest.mark.parametrize(("note", "question", "value"), [
    ("Jeg har en Støvet Blå jakke.", "Hvilken farve har min jakke?", "Støvet Blå"),
    ("Husk, at min hund hedder Molly-May.", "Hvad hedder min hund?", "Molly-May"),
    ("My cat is named Charlie.", "What's my cat's name?", "Charlie"),
    ("Mit fornavn er René.", "Hvad hedder jeg?", "René"),
    ("Min yndlingsfilm er »Blade Runner 2049«.", "Hvad var min yndlingsfilm?", "Blade Runner 2049"),
    ("Min livret er spaghetti carbonara.", "Hvad er min livret?", "spaghetti carbonara"),
    ("My favourite colour is midnight blue.", "What is my favorite color?", "midnight blue"),
])
def test_multiple_kinds_of_user_detail(note, question, value):
    assert f"»{value}«" in recall_reply(question, [user(note)], "da-DK")


def test_newer_correction_wins_and_unrelated_comments_do_not_overwrite():
    history = [user("Min cykel er blå."), user("Rettelse: Min cykel er ikke blå, men petrolblå."),
               user("Min cykel er punkteret."), user("Min bil er rød.")]
    assert recall_reply("Hvilken farve er min cykel?", history, "da-DK") == "Du skrev »petrolblå«."
    history.append(user("Min cykel er ikke længere petrolblå."))
    assert "sikkert svar" in recall_reply("Hvilken farve er min cykel?", history, "da-DK")


@pytest.mark.parametrize("turns", [
    [], [assistant("Min cykel er petrolblå.")], [user("Min kammerats cykel er petrolblå.")],
    [user("Jeg tror måske min cykel er blå.")], [user("Min cykel er blå?")],
    [user("Min cykel er enten blå eller rød.")], [user("Han skrev: »Min cykel er blå.«")],
    [user("Min bil er rød. Min hund hedder Luna.")],
])
def test_missing_or_ambiguous_evidence_returns_no_invented_fact(turns):
    assert "sikkert svar" in recall_reply("Hvilken farve har min cykel?", turns, "da-DK")


def test_do_not_repeat_sensitive_strings_or_instructions():
    turns = [user("Min hund hedder Luna, min adgangskode er ABC12345."),
             user("Min yndlingsfilm er adgangskode ABC12345.")]
    for question in ("Hvad hedder min hund?", "Hvad er min yndlingsfilm?"):
        assert "sikkert svar" in recall_reply(question, turns, "da-DK")
    assert recall_reply("Hvad er min adgangskode?", turns, "da-DK") is None


def test_retraction_changes_only_the_matching_topic_and_can_be_replaced():
    turns = [user("Min cykel er blå. Min bil er sort."), user("Glem farven på min cykel.")]
    assert "sikkert svar" in recall_reply("Hvilken farve har min cykel?", turns, "da-DK")
    assert "»sort«" in recall_reply("Hvilken farve har min bil?", turns, "da-DK")
    turns.append(user("Min cykel er ikke gul, den er petrolblå."))
    assert "»petrolblå«" in recall_reply("Hvilken farve har min cykel?", turns, "da-DK")
    turns.append(user("Glem alt i denne samtale."))
    assert "sikkert svar" in recall_reply("Hvilken farve har min bil?", turns, "da-DK")


@pytest.mark.parametrize("question", [
    "Hvad kan jeg lave med min cykel?", "Hvad hedder din kat?", "Hvilken farve er min vens cykel?",
    "Hvilken farve skal min bil være?", "Hvad er min livret, og hvor er min telefon?",
    "Kan du skrive en scene om min yndlingsfilm?",
    "Min yndlingsfilm",
])
def test_general_and_third_party_questions_keep_normal_chat(question):
    assert recall_reply(question, [user("Min yndlingsfilm er Dune.")], "da-DK") is None


@pytest.mark.parametrize(("note", "title"), [
    ("Min yndlingsfilm er Dr. Strangelove.", "Dr. Strangelove"),
    ("Min yndlingsfilm er »Dr. No«.", "Dr. No"),
    ('My favorite movie is "E.T. the Extra-Terrestrial".', "E.T. the Extra-Terrestrial"),
    ("Min yndlingsfilm er ‘Run. Hide. Fight.’.", "Run. Hide. Fight."),
])
def test_titles_keep_their_internal_punctuation(note, title):
    assert recall_reply("Hvad er min yndlingsfilm?", [user(note)], "da-DK") == f"Du skrev »{title}«."


@pytest.mark.parametrize("quote", [
    'Min ven skrev: "Hej.\nMin cykel er rød. Vi ses."',
    "Han sagde: »Hej. Min cykel er rød.\nVi ses.«",
    "Her er hendes besked:\nHej!\nMin cykel er rød.\nVi ses.",
    "My friend wrote: 'Hi. My bike is red. Goodbye.'",
    "Min ven skrev: “Hej. Min cykel er rød.",
    "> Hej. Min cykel er rød.\nVi ses.",
])
def test_reported_speech_cannot_overwrite_the_users_own_fact(quote):
    turns = [user("Min cykel er petrolblå."), user(quote)]
    assert recall_reply("Hvilken farve er min cykel?", turns, "da-DK") == "Du skrev »petrolblå«."
