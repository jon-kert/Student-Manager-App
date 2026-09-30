"""Task Planner - terminal CLI.

A thin client over the running Jac server, so the terminal, web and mobile
views all read and write the same graph. Every command spawns a server walker
through its REST endpoint (POST /walker/<name>).

    jac run cli.jac add "MATH 417" "Midterm Exam 1" 10/5
    jac run cli.jac today            # due today/tomorrow + overdue
    jac run cli.jac today 7          # everything due within 7 days
    jac run cli.jac done 4593b6      # any unique id prefix works
    jac run cli.jac start 4593b6     # mark In progress
    jac run cli.jac list [subject]   # every task, optional subject filter
    jac run cli.jac notify           # the mobile notification feed

Server URL: TASKPLANNER_URL (default http://localhost:8000).
"""

import json;
import os;
import sys;
import from urllib.request { Request, urlopen }
import from urllib.error { HTTPError, URLError }

glob BASE_URL: str = os.environ.get("TASKPLANNER_URL", "http://localhost:8000").rstrip("/");
glob USE_COLOR: bool = os.isatty(1) and not os.environ.get("NO_COLOR");

glob TYPE_LABELS: dict[str, str] = {"exam": "EXAM", "project": "PROJ", "optional": "OPT"};
glob URGENCY_LABELS: dict[str, str] = {
    "overdue": "overdue", "urgent": "urgent", "soon": "soon", "upcoming": "upcoming", "later": ""
};

# ---------------------------------------------------------------- wire types
# The server reports TaskView / NotificationFeed objects as JSON; land them in
# typed objs here so the rest of the CLI is fully type-checked.

obj Row {
    has id: str,
        subject: str,
        assignment_name: str,
        status: str,
        due_label: str,
        days_left: int,
        has_due: bool,
        type_tag: str,
        type_color: str,
        urgency_color: str,
        is_open: bool;

    static def parse(d: any) -> Row {
        return Row(
            id=str(d["id"]), subject=str(d["subject"]),
            assignment_name=str(d["assignment_name"]), status=str(d["status"]),
            due_label=str(d["due_label"]), days_left=int(d["days_left"]),
            has_due=bool(d["has_due"]), type_tag=str(d["type_tag"]),
            type_color=str(d["type_color"]), urgency_color=str(d["urgency_color"]),
            is_open=bool(d["is_open"])
        );
    }
}

# ---------------------------------------------------------------- http

def call_walker(name: str, body: dict[str, str | int]) -> list[any] {
    req = Request(
        f"{BASE_URL}/walker/{name}",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    );
    raw: str = "{}";
    try {
        resp: any = urlopen(req, timeout=10);
        raw = (resp.read() as bytes).decode("utf-8");
        resp.close();
    } except HTTPError as e {
        raw = (e.read() as bytes).decode("utf-8") or "{}";
    } except URLError {
        fail(f"Can't reach the server at {BASE_URL}. Start it with: jac start main.jac");
    }
    payload: any = json.loads(raw);
    if not payload.get("ok") {
        fail(str(payload.get("error", {}).get("message", "Unknown server error")));
    }
    return payload["data"]["reports"] as list[any];
}

def rows_from(name: str, body: dict[str, str | int]) -> list[Row] {
    return [Row.parse(d) for d in call_walker(name, body)];
}

def fail(msg: str) -> None {
    print(f"error: {msg}");
    sys.exit(1);
}

# ---------------------------------------------------------------- formatting

def paint(text: str, hex_color: str, background: bool = False) -> str {
    if not USE_COLOR or not hex_color {
        return text;
    }
    h = hex_color.lstrip("#");
    (r, g, b) = (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16));
    if background {
        # dark text on light fills (maize, light blue), white on dark (red)
        fg = "30" if (r * 299 + g * 587 + b * 114) / 1000 > 140 else "97";
        return f"\033[48;2;{r};{g};{b}m\033[{fg}m{text}\033[0m";
    }
    return f"\033[38;2;{r};{g};{b}m{text}\033[0m";
}

def days_text(t: Row) -> str {
    if not t.has_due {
        return "--";
    }
    d = t.days_left;
    if d < 0 {
        return f"{-d}d late";
    }
    return "today" if d == 0 else ("1 day" if d == 1 else f"{d} days");
}

def print_rows(rows: list[Row]) -> None {
    if not rows {
        print("Nothing to show.");
        return;
    }
    print(f"{'ID':<8}{'SUBJECT':<14}{'ASSIGNMENT':<30}{'STATUS':<14}{'DUE':<17}LEFT");
    for t in rows {
        tag = TYPE_LABELS.get(t.type_tag, "");
        name_cell = paint(f"{t.assignment_name[:28]:<30}", t.type_color);   # type highlight
        left = paint(f" {days_text(t):>8} ", t.urgency_color, background=True);   # urgency tier
        status = t.status if t.is_open else f"{t.status} ✓";
        print(
            f"{t.id[:6]:<8}{t.subject[:13]:<14}{name_cell}{status:<14}"
            + f"{t.due_label:<17}{left} {paint(tag, t.type_color)}"
        );
    }
}

def resolve_id(prefix: str) -> str {
    if len(prefix) == 32 {
        return prefix;
    }
    matches = [t.id for t in rows_from("get_tasks", {}) if t.id.startswith(prefix)];
    if len(matches) != 1 {
        fail(f"'{prefix}' matches {len(matches)} tasks - use more characters of the id.");
    }
    return matches[0];
}

# ---------------------------------------------------------------- commands

def cmd_add(args: list[str]) -> None {
    if len(args) < 2 {
        fail('usage: add <subject> <assignment name> [due: 9/30 | today | +3] [status]');
    }
    body: dict[str, str | int] = {"subject": args[0], "assignment_name": args[1]};
    if len(args) > 2 {
        body["due_date"] = args[2];
    }
    if len(args) > 3 {
        body["status"] = args[3];
    }
    t = rows_from("add_task", body)[0];
    print(f"Added {t.id[:6]}: {t.subject} / {t.assignment_name} - {t.due_label}");
}

def cmd_today(args: list[str]) -> None {
    within = int(args[0]) if args else 1;
    rows = rows_from("get_tasks", {"max_days": within, "status": "open"});
    label = "today & tomorrow" if within == 1 else f"the next {within} days";
    print(f"Open tasks due {label}:\n");
    print_rows(rows);
}

def cmd_set_status(args: list[str], status: str) -> None {
    if not args {
        fail("usage: done <id>   (the 6-character id from `today` or `list` is enough)");
    }
    t = rows_from("update_task_status", {"task_id": resolve_id(args[0]), "status": status})[0];
    print(f"{t.assignment_name} ({t.subject}) -> {t.status}");
}

def cmd_list(args: list[str]) -> None {
    body: dict[str, str | int] = {"subject": args[0]} if args else {};
    print_rows(rows_from("get_tasks", body));
}

def cmd_notify -> None {
    feed: any = call_walker("get_notifications", {})[0];
    print(f"{feed['count']} item(s) need attention\n");
    for (title, key) in [("Overdue", "overdue"), ("Due today / tomorrow", "due_now"), ("Exams & quizzes ahead", "exams")] {
        if feed[key] {
            print(paint(title, "#F28C28" if key == "exams" else "#E5383B"));
            print_rows([Row.parse(d) for d in feed[key]]);
            print("");
        }
    }
}

def usage -> None {
    print("""usage: jac run cli.jac <command> [args]

  add <subject> <name> [due] [status]   quick entry  (due: 9/30, 2026-09-30, today, +3)
  today [days]                          open tasks due within N days (default 1) + overdue
  done <id>                             mark Done        (6-char id prefix is enough)
  start <id> | skip <id>                mark In progress / Skipped
  list [subject]                        every task, optionally filtered by subject
  notify                                overdue, due-now and upcoming exams

Server: $TASKPLANNER_URL (default http://localhost:8000)""");
}

with entry:__main__ {
    argv = sys.argv[1:];
    command = argv[0] if argv else "today";
    rest = argv[1:];
    match command {
        case "add":
            cmd_add(rest);
        case "today":
            cmd_today(rest);
        case "done":
            cmd_set_status(rest, "Done");
        case "start" | "progress":
            cmd_set_status(rest, "In progress");
        case "skip":
            cmd_set_status(rest, "Skipped");
        case "list" | "ls":
            cmd_list(rest);
        case "notify":
            cmd_notify();
        case _:
            usage();
    }
}
