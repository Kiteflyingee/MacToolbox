#!/usr/bin/env python3
"""Check this design handoff, not the future App. Python standard library only."""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
CORE_IDS = {
    "CORE-FINDER", "CORE-HISTORY", "TR-SCREEN", "TR-COPY", "TR-API", "TR-DIRECTION"
}
EXPECTED_TASKS = {f"T{i:02d}" for i in range(29)} | {f"S{i:02d}" for i in range(1, 5)}


def read_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def indexed(items, label, errors):
    result = {}
    for item in items:
        key = item.get("id")
        if not isinstance(key, str) or not key:
            errors.append(f"{label}: missing ID")
        elif key in result:
            errors.append(f"{label}: duplicate {key}")
        else:
            result[key] = item
    return result


def validate(trace_path):
    errors = []
    trace = read_json(trace_path)
    if trace.get("schema_version") != 1:
        errors.append("Unsupported traceability schema_version")
    catalog = read_json(ROOT / trace["scope_source"])
    selected = {item["id"] for item in catalog if item["selection"] == "保留"}
    excluded = {item["id"] for item in catalog if item["selection"] != "保留"}
    if len(selected) != 29:
        errors.append(f"Scope source has {len(selected)} retained items; expected 29")
    reqs = indexed(trace["requirements"], "requirement", errors)
    tasks = indexed(trace["tasks"], "task", errors)
    tests = indexed(trace["tests"], "check", errors)
    expected_reqs = selected | CORE_IDS
    for key in sorted(expected_reqs - reqs.keys()):
        errors.append(f"Missing requirement: {key}")
    for key in sorted(reqs.keys() - expected_reqs):
        errors.append(f"Unexpected/out-of-scope requirement: {key}")
    if reqs.keys() & excluded:
        errors.append("Excluded reference capabilities appear as requirements")
    if tasks.keys() != EXPECTED_TASKS:
        errors.append("Tasks must be T00–T28 and S01–S04 exactly")
    if set(trace.get("gate_ids", [])) != {"S01", "S02", "S03", "S04"}:
        errors.append("Platform gate IDs differ from S01–S04")

    acceptance_path = ROOT / "docs/implementation/验收矩阵.md"
    acceptance = acceptance_path.read_text(encoding="utf-8")
    acceptance_ids = set(re.findall(r"^\| ((?:AT-|GATE-|INT-|ENV-|REL-)[A-Z0-9-]+) \|", acceptance, re.M))
    if acceptance_ids != tests.keys():
        errors.append(
            "Acceptance rows differ from check registry: missing="
            + str(sorted(tests.keys() - acceptance_ids))
            + ", unregistered=" + str(sorted(acceptance_ids - tests.keys()))
        )

    for key, req in reqs.items():
        for field, known in (("tasks", tasks), ("tests", tests)):
            refs = req.get(field, [])
            if not refs or len(refs) != len(set(refs)):
                errors.append(f"{key}: {field} must be nonempty and unique")
            for ref in refs:
                if ref not in known:
                    errors.append(f"{key}: unknown {field} reference {ref}")
        covered = {test for task_id in req.get("tasks", []) if task_id in tasks
                   for test in tasks[task_id].get("tests", [])}
        if not set(req.get("tests", [])).issubset(covered):
            errors.append(f"{key}: mapped tasks do not own its checks")
        if not re.search(r"^\| AT-[^|]+\| " + re.escape(key) + r" \|", acceptance, re.M):
            errors.append(f"{key}: no explicit requirement row in acceptance matrix")

    work = (ROOT / "docs/implementation/工作包.md").read_text(encoding="utf-8")
    sections = {}
    for match in re.finditer(r"^## ([TS]\d{2}) — [^\n]+\n(.*?)(?=^## |\Z)", work, re.M | re.S):
        key, body = match.group(1), match.group(2)
        if key in sections:
            errors.append(f"Duplicate work package section: {key}")
        sections[key] = body
    if sections.keys() != tasks.keys():
        errors.append("Work package sections differ from task registry")

    for key, task in tasks.items():
        deps = task.get("depends_on", [])
        if len(deps) != len(set(deps)):
            errors.append(f"{key}: duplicate dependencies")
        for dep in deps:
            if dep not in tasks or dep == key:
                errors.append(f"{key}: invalid dependency {dep}")
        if not task.get("tests"):
            errors.append(f"{key}: no verification checks")
        for check in task.get("tests", []):
            if check not in tests:
                errors.append(f"{key}: unknown check {check}")
        body = sections.get(key, "")
        for label in ("**依赖：**", "**目标文件：**", "**完成证据：**", "**停止条件：**"):
            if label not in body:
                errors.append(f"{key}: missing field {label}")
        dep_line = re.search(r"\*\*依赖：\*\*([^。\n]+)", body)
        if dep_line:
            documented = set(re.findall(r"\b[TS]\d{2}\b", dep_line.group(1)))
            if documented != set(deps):
                errors.append(f"{key}: documented dependencies disagree with registry")
        if len(re.findall(r"^\d+\. ", body, re.M)) < 3:
            errors.append(f"{key}: fewer than three implementation steps")

    # DFS catches cycles even when a dependency points forward in display order.
    visiting, done = set(), set()

    def visit(key):
        if key in visiting:
            errors.append(f"Dependency cycle at {key}")
            return
        if key in done or key not in tasks:
            return
        visiting.add(key)
        for dep in tasks[key].get("depends_on", []):
            visit(dep)
        visiting.remove(key)
        done.add(key)

    for key in tasks:
        visit(key)

    # Check deliverable links, not future Swift filenames shown as inline code.
    markdown_files = [ROOT / "README.md", ROOT / "CONTEXT.md"] + sorted((ROOT / "docs").rglob("*.md"))
    for path in markdown_files:
        body = path.read_text(encoding="utf-8")
        body = re.sub(r"```.*?```", "", body, flags=re.S)
        if re.search(r"\[(?:TODO|待补充|To be written)\]", body, re.I):
            errors.append(f"Unfinished placeholder in {path.relative_to(ROOT)}")
        for match in re.finditer(r"(?<!!)\[[^\]\n]+\]\(([^)\n]+)\)", body):
            target = match.group(1).strip().strip("<>")
            parsed = urlsplit(target)
            if parsed.scheme or target.startswith("#"):
                continue
            local = unquote(parsed.path)
            if local and not (path.parent / local).resolve().exists():
                errors.append(f"Broken local link in {path.relative_to(ROOT)}: {target}")
    return errors, len(reqs), len(tasks), len(tests)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--traceability", type=Path,
                        default=ROOT / "docs/implementation/traceability.json")
    args = parser.parse_args()
    try:
        errors, req_count, task_count, test_count = validate(args.traceability)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"FAIL: cannot read design package: {exc}", file=sys.stderr)
        return 1
    if errors:
        for error in errors:
            print("FAIL: " + error, file=sys.stderr)
        return 1
    print(f"PASS: {req_count} requirements (29 selected + 6 core), {task_count} tasks, "
          f"{test_count} checks; dependencies, ownership, sections and local links are consistent.")
    print("Design validation only. The App has not been built or acceptance-tested by this script.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
