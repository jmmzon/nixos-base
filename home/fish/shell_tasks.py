"""Task board for the fish welcome banner (my.shellTasks).

Reads the task script's `list --json` output on stdin (the format of
my.taskBoard.script) and prints up to three columns:

  progress   ACTIVE tasks
  todo       OPEN and REVIEW tasks
  attention  open tasks whose review is overdue or due within 2 days

A task in attention is left out of the other two. Each column is ordered by
priority (high first), then the earliest review date. Epics are listed only on
the line under the columns, with their progress; epic children only when
ACTIVE. `↑` marks high priority and `!` an overdue review. Columns that do
not fit side by side are stacked.

With --root, task IDs are terminal hyperlinks (OSC 8): to --link-base + path
when the file matches the checkout's upstream branch (pushed), otherwise to
the local file (committed but unpushed, uncommitted or new; also with no
upstream or no link base).

  shell_tasks.py --rows N --columns progress,todo,attention --width COLUMNS
                 [--root CHECKOUT [--link-base URL] [--git GIT]]
"""

import argparse
import datetime
import json
import subprocess
import sys
import urllib.parse

DUE_SOON_DAYS = 2
GAP = 3
MIN_COLUMN = 30  # narrower columns stack instead
TITLES = {"progress": "In progress", "todo": "To do", "attention": "Needs attention"}
PRIORITY_RANK = {"high": 0, "medium": 1, "low": 2}

BOLD, DIM, RESET = "\033[1m", "\033[2m", "\033[0m"
ACCENT = "\033[38;2;54;241;205m"  # the banner gradient's first colour
HIGH = "\033[38;2;250;200;80m"
LATE = "\033[38;2;245;100;100m"


def link(url, text):
    return f"\033]8;;{url}\033\\{text}\033]8;;\033\\" if url and text else text


def unpushed(git, root):
    """Paths under tasks/ that differ from the upstream branch, or None when
    there is no upstream (nothing counts as pushed then)."""
    def run(*args):
        result = subprocess.run([git, "-C", root, *args], capture_output=True, text=True)
        return result.stdout.splitlines() if result.returncode == 0 else None
    changed = run("diff", "--name-only", "@{upstream}", "--", "tasks/")
    if changed is None:
        return None
    return set(changed) | set(run("ls-files", "--others", "--exclude-standard", "--", "tasks/") or [])


def linker(root, link_base, git):
    """A function from a task (with its repository-relative path) to its URL."""
    if not root:
        return lambda task: None
    local = unpushed(git, root) if link_base else None

    def url(task):
        path = task.get("path")
        if not path:
            return None
        if local is not None and path not in local:
            return link_base + path
        return "file://" + urllib.parse.quote(f"{root.rstrip('/')}/{path}")
    return url


def cut(text, width):
    return text if len(text) <= width else text[: max(width - 1, 0)] + "…"


def order(task):
    return (PRIORITY_RANK.get(task.get("priority"), 1), task.get("review") or "9999-99-99", task["id"])


def columns_of(board, wanted):
    today = datetime.date.fromisoformat(board["today"])
    soon = (today + datetime.timedelta(days=DUE_SOON_DAYS)).isoformat()
    epic_ids = {e["id"] for e in board.get("epics", [])}
    groups = {"progress": [], "todo": [], "attention": []}
    for task in board.get("tasks", []):
        if task["id"] in epic_ids:
            continue  # on the epics line
        if task.get("epic") and task["status"] != "ACTIVE":
            continue
        review = task.get("review")
        if "attention" in wanted and review and review <= soon:
            groups["attention"].append(task)
        elif task["status"] == "ACTIVE":
            groups["progress"].append(task)
        else:
            groups["todo"].append(task)
    return [(name, sorted(groups[name], key=order)) for name in wanted]


def entry(task, width, url):
    """(plain, coloured) line for one task, cut to width."""
    high = task.get("priority") == "high"
    late = bool(task.get("overdue"))
    marks = ("↑" if high else " ") + ("!" if late else " ")
    plain = cut(f"{marks}{task['id']} {task['title']}", width)
    text = plain[2:]
    ident = len(task["id"]) if text.startswith(task["id"]) else 0
    coloured = (
        (HIGH + "↑" + RESET if high else " ")
        + (LATE + "!" + RESET if late else " ")
        + link(url(task), text[:ident])
        + text[ident:]
    )
    return plain, coloured


def column_lines(name, tasks, rows, width, url):
    header = cut(f"{TITLES[name]} ({len(tasks)})", width)
    lines = [(header, BOLD + ACCENT + header + RESET)]
    shown = tasks if len(tasks) <= rows else tasks[: max(rows - 1, 0)]
    lines += [entry(t, width, url) for t in shown]
    if not tasks:
        lines.append(("  —", DIM + "  —" + RESET))
    elif len(shown) < len(tasks):
        more = f"  +{len(tasks) - len(shown)} more"
        lines.append((more, DIM + more + RESET))
    return lines


def epics_line(board, width, url):
    parts = []
    for epic in board.get("epics", []):
        done, total = epic.get("done", 0), epic.get("total", 0)
        # Any progress shows at least one cell; only a finished epic shows four.
        filled = min(-(-4 * done // total), 4 if done == total else 3) if total else 0
        mark = LATE + "!" + RESET if epic.get("overdue") else ""
        plain = f"{epic['id']} {'▰' * filled}{'▱' * (4 - filled)} {done}/{total}"
        coloured = link(url(epic), epic["id"]) + plain[len(epic["id"]):]
        parts.append((plain + ("!" if mark else ""), coloured + mark))
    if not parts:
        return None
    label = "Epics  "
    plain_out, coloured_out = label, BOLD + ACCENT + label + RESET
    for index, (plain, coloured) in enumerate(parts):
        sep = " · " if index else ""
        more = f" +{len(parts) - index - 1}" if index < len(parts) - 1 else ""
        if index and len(plain_out) + len(sep) + len(plain) + len(more) > width:
            more = f" +{len(parts) - index}"
            return plain_out + more, coloured_out + DIM + more + RESET
        plain_out += sep + plain
        coloured_out += (DIM + sep + RESET if sep else "") + coloured
    return plain_out, coloured_out


def render(board, rows, wanted, width, url=lambda task: None):
    columns = columns_of(board, wanted)
    out = []
    if columns:
        column_width = (width - GAP * (len(columns) - 1)) // len(columns)
        if column_width >= MIN_COLUMN:
            blocks = [column_lines(n, t, rows, column_width, url) for n, t in columns]
            for index in range(max(len(b) for b in blocks)):
                line = ""
                for number, block in enumerate(blocks):
                    plain, coloured = block[index] if index < len(block) else ("", "")
                    pad = "" if number == len(blocks) - 1 else " " * (column_width - len(plain) + GAP)
                    line += coloured + pad
                out.append(line.rstrip())
        else:
            for number, (name, tasks) in enumerate(columns):
                if number:
                    out.append("")
                out += [c for _, c in column_lines(name, tasks, rows, width, url)]
    epics = epics_line(board, width, url)
    if epics:
        out += ["", epics[1]]
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=4)
    parser.add_argument("--columns", default="progress,todo,attention")
    parser.add_argument("--width", type=int, default=80)
    parser.add_argument("--root", default="")
    parser.add_argument("--link-base", default="")
    parser.add_argument("--git", default="git")
    args = parser.parse_args()
    wanted = [c for c in args.columns.split(",") if c in TITLES]
    try:
        board = json.load(sys.stdin)
    except ValueError:
        return  # no board rather than a traceback in every new shell
    url = linker(args.root, args.link_base, args.git)
    for line in render(board, max(args.rows, 1), wanted, max(args.width, 20), url):
        print(line)


if __name__ == "__main__":
    main()
