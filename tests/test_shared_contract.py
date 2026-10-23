import json
from types import SimpleNamespace

from langchain_classic.retrievers import EnsembleRetriever
from langchain_core.documents import Document

from food import canonicalize, config, db, normalize, resolve
from food.ingest import costco
import importlib

web_app = importlib.import_module("food.web.app")


def _fixture(name: str) -> dict:
    return json.loads((config.SHARED_DIR / "fixtures" / name).read_text())


def test_shared_schema_prompts_query_and_config_are_loaded():
    assert db.SCHEMA == (config.SHARED_DIR / "schema.sql").read_text()
    assert canonicalize.SYSTEM == config.SHARED_PROMPTS["canonicalize"]
    assert resolve.RESEARCH_SYSTEM == config.SHARED_PROMPTS["research"]
    assert resolve.SYNTH_SYSTEM == config.SHARED_PROMPTS["synthesis"]
    assert web_app.CHAT_SYSTEM == config.SHARED_PROMPTS["chat"]
    assert costco.QUERY == (config.SHARED_DIR / "costco.graphql").read_text().strip()
    assert resolve.JEV_DAY_CRITERIA == config.SHARED_JEV["day_criteria"]
    assert resolve.JEV_STORAGE_CRITERIA == config.SHARED_JEV["storage_criteria"]
    assert config.SHARED_CONFIG["jev_model"] == config.JEV_MODEL


def test_normalize_costco_golden():
    fixture = _fixture("normalize_costco.json")
    receipts = normalize.normalize_costco(fixture["raw"])
    assert receipts[0].model_dump(exclude={"raw"}) == fixture["expected"]


def test_rrf_golden():
    fixture = _fixture("rrf.json")
    dummy = SimpleNamespace(weights=fixture["weights"], c=fixture["c"], id_key=None)
    ranked = EnsembleRetriever.weighted_reciprocal_rank(
        dummy,
        [[Document(page_content=str(i)) for i in ids] for ids in fixture["lists"]],
    )
    assert [int(d.page_content) for d in ranked] == fixture["expected"]


def test_jev_verdicts_golden(monkeypatch):
    fixture = _fixture("jev_verdicts.json")
    shortlists = {int(k): v for k, v in fixture["shortlists"].items()}
    monkeypatch.setattr(resolve.jev, "is_configured", lambda: True)
    monkeypatch.setattr(
        resolve.jev,
        "decide",
        lambda state, questions: {
            "model": "fixture",
            "answers": fixture["answers"],
            "usage": {"input_tokens": 1, "output_tokens": 1},
        },
    )
    verdicts, _ = resolve._jev_verdicts(fixture["items"], shortlists, "fixture notes")
    got = {
        str(i): {
            "source": v.source,
            "shelf_life_days": v.shelf_life_days,
            "shelf_life_days_opened": v.shelf_life_days_opened,
            "storage": v.storage,
            "is_perishable": v.is_perishable,
            "confidence": v.confidence,
        }
        for i, v in verdicts.items()
    }
    assert got == fixture["expected"]
