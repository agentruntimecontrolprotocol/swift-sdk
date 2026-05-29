#!/usr/bin/env python3
"""Generate Markdown API docs by scraping `///` doc comments from Swift sources.

Walks `Sources/ARCP/<Module>/**/*.swift` and `Sources/arcp-cli/**/*.swift`,
groups symbols by top-level subdirectory, and emits one .md per module plus
an `index.md`. Output goes to `docs/api/` relative to the swift-sdk root.

Usage: python3 scripts/gen-api-docs.py
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
OUT = ROOT / "docs" / "api"

DECL_RE = re.compile(
    r"^(?P<indent>\s*)"
    r"(?P<attrs>(?:@\w+(?:\([^)]*\))?\s+)*)"
    r"(?P<mods>(?:(?:public|open|internal|private|fileprivate|final|static|"
    r"class|nonisolated|isolated|indirect|override|convenience|required|"
    r"mutating|nonmutating|dynamic|lazy|weak|unowned|async|throws|rethrows)"
    r"\s+)*)"
    r"(?P<kind>protocol|struct|class|enum|actor|extension|"
    r"func|init|deinit|subscript|var|let|typealias|associatedtype|case)"
    r"\b(?P<rest>.*)$"
)

PUBLIC_MODS = {"public", "open"}
CONTAINER_KINDS = {"protocol", "struct", "class", "enum", "actor", "extension"}


@dataclass
class Symbol:
    kind: str
    name: str
    signature: str
    docs: list[str]
    file: Path
    line: int
    nested_in: str | None = None


@dataclass
class Module:
    name: str
    symbols: list[Symbol] = field(default_factory=list)


def extract_doc_block(lines: list[str], idx: int) -> list[str]:
    doc: list[str] = []
    j = idx - 1
    while j >= 0:
        s = lines[j].strip()
        if s.startswith("///"):
            doc.append(s[3:].lstrip())
            j -= 1
            continue
        if s.startswith("@") and not doc:
            j -= 1
            continue
        break
    doc.reverse()
    return doc


def _init_labels(rest: str, sigil: str) -> str:
    """Build init(a:b:) label list from parameter source after `init`."""
    m = re.match(r"\s*\(", rest)
    if not m:
        return f"init{sigil}"
    body, depth, end = rest[m.end():], 1, -1
    for i, ch in enumerate(body):
        depth += (ch == "(") - (ch == ")")
        if depth == 0:
            end = i
            break
    inner = body[:end] if end >= 0 else body
    params, buf, d = [], [], 0
    for ch in inner:
        if ch in "([<":
            d += 1
        elif ch in ")]>":
            d -= 1
        if ch == "," and d == 0:
            params.append("".join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    if buf:
        params.append("".join(buf).strip())
    labels = []
    for p in (x for x in params if x):
        toks = [t for t in p.split() if not t.startswith("@")]
        labels.append(toks[0].rstrip(":") if toks else "_")
    return f"init{sigil}({''.join(l + ':' for l in labels)})"


def symbol_name(kind: str, rest: str) -> str:
    rest = rest.strip()
    if kind == "init":
        sig = re.match(r"([?!]?)", rest)
        return _init_labels(rest[sig.end():], sig.group(1))
    if kind in {"deinit", "subscript"}:
        return kind
    rest = rest.lstrip("`")
    m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", rest)
    return m.group(1) if m else (rest.split()[0] if rest else "<unknown>")


def signature_text(lines: list[str], idx: int) -> str:
    """Join continuation lines until parens balance and the decl head ends."""
    sig = lines[idx].rstrip()
    j = idx
    while j - idx < 20:
        depth = sig.count("(") - sig.count(")")
        stripped = sig.rstrip()
        ends_open = stripped.endswith(("{",))
        if depth <= 0 and (ends_open or (not stripped.endswith(",")
                                         and not stripped.endswith("("))):
            break
        j += 1
        if j >= len(lines):
            break
        sig += "\n" + lines[j].rstrip()
    return re.sub(r"\s*\{\s*$", "", sig).strip()


def parse_file(path: Path) -> list[Symbol]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    symbols: list[Symbol] = []
    # stack entries: (name, kind, brace_depth_at_open, is_public)
    stack: list[tuple[str, str, int, bool]] = []
    brace_depth = 0
    for i, raw in enumerate(lines):
        while stack and brace_depth <= stack[-1][2]:
            stack.pop()
        m = DECL_RE.match(raw)
        if m:
            mods = (m.group("attrs") + " " + m.group("mods")).split()
            kind = m.group("kind")
            parent = stack[-1] if stack else None
            p_kind = parent[1] if parent else None
            p_pub = parent[3] if parent else True
            if kind == "case":
                include = (p_kind == "enum" and p_pub
                           and brace_depth == parent[2] + 1)
            else:
                include = bool(PUBLIC_MODS & set(mods))
                if not include and p_kind == "protocol" and p_pub:
                    include = True
            if include:
                rest = m.group("rest")
                sig = signature_text(lines, i)
                if kind in {"init", "subscript"}:
                    after = sig.split(kind, 1)[1] if kind in sig else rest
                    name = symbol_name(kind, after)
                else:
                    name = symbol_name(kind, rest)
                symbols.append(Symbol(
                    kind=kind, name=name, signature=sig,
                    docs=extract_doc_block(lines, i),
                    file=path, line=i + 1,
                    nested_in=".".join(s[0] for s in stack) if stack else None,
                ))
            if kind in CONTAINER_KINDS and "{" in raw:
                is_pub = bool(PUBLIC_MODS & set(mods)) or p_pub
                stack.append((symbol_name(kind, m.group("rest")), kind,
                              brace_depth, is_pub))
        brace_depth += raw.count("{") - raw.count("}")
    return symbols


def collect_modules() -> dict[str, Module]:
    modules: dict[str, Module] = {}
    for swift in sorted(SOURCES.rglob("*.swift")):
        parts = swift.relative_to(SOURCES).parts
        if parts[0] == "ARCP" and len(parts) > 1:
            module = parts[1] if (SOURCES / parts[0] / parts[1]).is_dir() else "Core"
        else:
            module = parts[0]
        modules.setdefault(module, Module(name=module)).symbols.extend(parse_file(swift))
    return modules


def render_symbol(sym: Symbol) -> str:
    title = sym.name if not sym.nested_in else f"{sym.nested_in}.{sym.name}"
    rel = sym.file.relative_to(ROOT)
    parts = [
        f"### `{title}` — {sym.kind}",
        f"*Defined in `{rel}:{sym.line}`*",
        "",
        "```swift",
        sym.signature,
        "```",
    ]
    if sym.docs:
        parts += ["", "\n".join(sym.docs)]
    parts.append("")
    return "\n".join(parts)


def render_module(mod: Module) -> str:
    out = [f"# {mod.name}", ""]
    if not mod.symbols:
        out.append("_No public symbols._")
        return "\n".join(out) + "\n"
    by_kind: dict[str, list[Symbol]] = {}
    for s in mod.symbols:
        by_kind.setdefault(s.kind, []).append(s)
    out.append("## Contents")
    for kind in sorted(by_kind):
        names = ", ".join(f"`{s.name}`" for s in by_kind[kind])
        out.append(f"- **{kind}**: {names}")
    out += ["", "## Symbols", ""]
    out.extend(render_symbol(s) for s in mod.symbols)
    return "\n".join(out) + "\n"


def render_index(modules: dict[str, Module]) -> str:
    header = ("# Swift SDK API Reference\n\nAuto-generated from `///` doc "
              "comments in `Sources/`. Regenerate with `make docs-api` from "
              "the swift-sdk root.\n\n## Modules\n\n")
    items = [f"- [{n}](./{n}.md) — {len(modules[n].symbols)} public symbol"
             f"{'s' if len(modules[n].symbols) != 1 else ''}"
             for n in sorted(modules)]
    return header + "\n".join(items) + "\n"


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    modules = collect_modules()
    count = 0
    for name, mod in modules.items():
        (OUT / f"{name}.md").write_text(render_module(mod), encoding="utf-8")
        count += 1
    (OUT / "index.md").write_text(render_index(modules), encoding="utf-8")
    count += 1
    total = sum(len(m.symbols) for m in modules.values())
    print(f"wrote {count} markdown files to {OUT.relative_to(ROOT)}")
    print(f"modules: {len(modules)}, public symbols: {total}")


if __name__ == "__main__":
    main()
