#!/usr/bin/env python3
"""check-alert-actions.py — every alert says what a person does first (neenv patterns/alert-runbooks).

    check-alert-actions.py <rules.yml>...      exit 0 when every alerting rule carries non-empty `summary`,
                                               `description` and `action` annotations; exit 1 and name each one that
                                               does not; exit 2 when a file cannot be read.

An alert that wakes someone and does not say what to do first is a page that teaches nothing. The action is one
sentence: the first command or look, not a diagnosis.
"""
import sys
import yaml

REQUIRED = ("summary", "description", "action")


def main(paths):
    missing, total = [], 0
    for path in paths:
        try:
            with open(path) as fh:
                doc = yaml.safe_load(fh)
        except (OSError, yaml.YAMLError) as exc:
            print(f"cannot read {path}: {exc}", file=sys.stderr)
            return 2
        for group in (doc or {}).get("groups") or []:
            for rule in group.get("rules") or []:
                if "alert" not in rule:
                    continue
                total += 1
                ann = rule.get("annotations") or {}
                lacks = [k for k in REQUIRED if not str(ann.get(k) or "").strip()]
                if lacks:
                    missing.append(f"{path}: {rule['alert']} lacks {', '.join(lacks)}")
    if total == 0:
        print("no alerting rules found: refusing to call that a pass", file=sys.stderr)
        return 2
    for line in missing:
        print(line)
    print(f"{total} alert(s), {len(missing)} without what to do first")
    return 1 if missing else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1:]))
