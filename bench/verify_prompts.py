"""Verify the Swift port's schema + prompts are byte-identical to the Python sources."""
import ast, difflib, re, sys, textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # repo root (bench/ -> root)
FOOD = ROOT / "food"
CORE = ROOT / "mobile/ios/FoodCore/Sources/FoodCore"


def _assigned(node, name: str):
    if isinstance(node, ast.Assign):
        if any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return node.value
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name:
        return node.value
    return None


def py_string(path: Path, name: str) -> str:
    for node in ast.parse(path.read_text()).body:
        value = _assigned(node, name)
        if value is not None:
            return ast.literal_eval(value)
    raise SystemExit(f"{name} not found in {path}")


def py_migration(path: Path, version: int) -> str:
    for node in ast.parse(path.read_text()).body:
        value = _assigned(node, "MIGRATIONS")
        if value is not None:
            for item in ast.literal_eval(value):
                if item[0] == version:
                    return item[1]
    raise SystemExit(f"migration {version} not found in {path}")


def swift_strings(path: Path, name: str) -> list[str]:
    """The string literal assigned to `static let <name>` — a multiline `\"\"\"` block or a
    single-line literal. Multiline blocks are dedented by their closing-delimiter indent."""
    src = path.read_text()
    start = src.find(f"static let {name}")
    if start < 0:
        return []
    m = re.search(r'"""\n(.*?)\n(\s*)"""', src[start:], re.S)
    if m:
        body, indent = m.group(1), m.group(2)
        return ["\n".join(
            line[len(indent):] if line.startswith(indent) else line for line in body.split("\n")
        )]
    single = re.search(r'=\s*"((?:[^"\\]|\\.)*)"', src[start:])
    if single:
        return [single.group(1).replace('\\"', '"').replace("\\n", "\n")]
    return []


def norm_sql(text: str) -> str:
    """SQL whitespace/indentation is insignificant; compare the statements, not the layout."""
    return "\n".join(
        line.rstrip() for line in textwrap.dedent(text).strip("\n").split("\n")
    )


def check(label: str, py: str, swift: str, prefix_only: bool = False) -> bool:
    a, b = py.strip("\n"), swift.strip("\n")
    ok = b.startswith(a) if prefix_only else a == b
    print(f"{'OK  ' if ok else 'DIFF'}  {label}")
    if not ok:
        for line in list(difflib.unified_diff(a.split("\n"), b.split("\n"), "python", "swift", lineterm=""))[:24]:
            print("    ", line)
    return ok


ok = True
ok &= check(
    "schema (db.py SCHEMA)",
    norm_sql(py_string(FOOD / "db.py", "SCHEMA")),
    norm_sql(swift_strings(CORE / "Schema.swift", "ddl")[0]),
)
ok &= check(
    "migration v2",
    norm_sql(py_migration(FOOD / "db.py", 2)),
    norm_sql(swift_strings(CORE / "Schema.swift", "migrations")[0]),
)
ok &= check("canonicalize SYSTEM", py_string(FOOD / "canonicalize.py", "SYSTEM"), swift_strings(CORE / "Canonicalize.swift", "system")[0])
ok &= check("chat CHAT_SYSTEM", py_string(FOOD / "web/app.py", "CHAT_SYSTEM"), swift_strings(CORE / "Chat.swift", "system")[0])
ok &= check(
    "digest prompt",
    "You are a practical home cook. Given items about to expire, suggest what to make.",
    swift_strings(CORE / "Chat.swift", "digestSystem")[0],
)
ok &= check(
    "resolve RESEARCH_SYSTEM",
    py_string(FOOD / "resolve.py", "RESEARCH_SYSTEM"),
    swift_strings(CORE / "ShelfLifeAgent.swift", "researchSystem")[0],
)
ok &= check(
    "resolve SYNTH_SYSTEM",
    py_string(FOOD / "resolve.py", "SYNTH_SYSTEM"),
    swift_strings(CORE / "ShelfLifeAgent.swift", "synthSystem")[0],
)

print("\nRESULT:", "ALL MATCH" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
