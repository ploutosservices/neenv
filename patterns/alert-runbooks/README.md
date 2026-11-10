# A runbook per alert

## The problem

An alert that wakes someone and does not say what to do first is a page that teaches nothing. The person reads
"disk usage above 80%", knows it is bad, and starts from zero. A separate runbook wiki answers that, until it drifts
from the alerts it describes: an alert is renamed, a new one is added, and its page is never written.

## What runs here

**The runbook is in the alert.** Every alert carries three annotations, and the third is the runbook:

| Annotation | What it says |
|---|---|
| `summary` | what is wrong, on which machine, in one line |
| `description` | why it matters and what the alert measured |
| `action` | **what a person does first**: one sentence, a command or a look, not a diagnosis |

The action travels with the alert. The message that reaches a person (chat and mail, through Alertmanager's
template) ends with "**First:** …" while the alert fires, and drops it when it resolves.

**A check refuses an alert without one.** The configuration repository's CI runs
[`check-alert-actions.py`](check-alert-actions.py) over every rule file: an alerting rule missing `summary`,
`description` or `action` turns the configuration's CI run red. So a new alert cannot be added without saying what to do about it, and the
runbook cannot drift away from the alert, because it is the alert. When this pattern was written, all 50 alerts here
were given an action, the check passed, and every change to the rules is checked from then on.

**What makes a good action.** It names the first command or the first place to look, on the machine the alert names:
`du -xh --max-depth=2 <mountpoint> | sort -h | tail` for a filling disk, `systemctl status <unit>` and
`journalctl -u <unit> -n 50` for a failed unit, "copy what matters off the drive now" for a failing drive. It does not
explain the alert (that is the description) and does not try to be the whole procedure; a long procedure belongs in
the pattern for that part of the system, and the action points there.

**Alertmanager's template**, the line that shows it (Go templates, inside the template's `{{ range .Alerts }}`, where
each alert's `.Status` is `firing` or `resolved`):

```
{{ with .Annotations.description }} — {{ . }}{{ end }}{{ if ne .Status "resolved" }}{{ with .Annotations.action }} **First:** {{ . }}{{ end }}{{ end }}
```

**promtool tests and the action.** promtool's unit tests compare an alert's annotations in full, so a test that
expects an alert must expect its action too. That is a feature: a changed action changes its test.

## The configuration, with example values

```yaml
- alert: DiskSpaceLow
  expr: (1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) > 0.8
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "{{ $labels.instance }}: disk {{ $labels.mountpoint }} over 80%"
    description: "Disk usage is above 80% on {{ $labels.instance }} ({{ $labels.mountpoint }})."
    action: "Run `du -xh --max-depth=2 {{ $labels.mountpoint }} | sort -h | tail` on {{ $labels.instance }} and remove or move what grew; never delete a backup to make room."
```

In CI, after `promtool check rules` and `promtool test rules`:

```
python3 scripts/check-alert-actions.py $(grep -l '^groups:' monitoring/*.yml)
```

## The drill

[`drill-runbooks.sh`](drill-runbooks.sh) needs no credential. It writes three example alerts, each with all three
annotations, and runs the check. With `ARM=noaction` one alert loses its action, and exactly that alert must be named.
`./drill-runbooks.sh check FILE...` runs the check on your own rules. Needs python3 with PyYAML.

```
$ ./drill-runbooks.sh
3 alert(s), 0 without what to do first
all checks passed

$ ARM=noaction ./drill-runbooks.sh
.../rules.yml: InstanceDown lacks action
3 alert(s), 1 without what to do first
ARM: exactly the alert without an action was named, as it must
```

The check refuses an empty set of rules (exit 2) rather than call it a pass.

## What is still open

- **The check sees that an action exists, not that it is right.** A wrong first step passes. Reviewing an alert's
  action is part of reviewing the alert.
- **Recording rules and dashboards** are not covered; only alerts page a person.
