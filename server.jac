"""Task Planner - server (graph model, highlight rules, CRUD walkers).

Graph shape (persisted by the Jac runtime in .jac/data between sessions):

    root --> category_root(subject="MATH 4...")  -[task_edge]-> task(...)
         --> category_root(subject="Job Search") -[task_edge]-> task(...)

Every walker is `walker:pub`, so the web app, the mobile app and the CLI can
call it without logging in and all of them share one graph (this is a
single-person planner). To give each user a private graph instead, drop `:pub`
(making the walkers authenticated) and log in from each client.
"""

import from datetime { date, datetime, timedelta }

# ---------------------------------------------------------------- constants

glob STATUSES: list[str] = ["Not started", "In progress", "Done", "Skipped"];
glob CLOSED_STATUSES: list[str] = ["Done", "Skipped"];

# Type highlights (from the spreadsheet). Checked in this order, so a name
# like "Optional Quiz" is orange (exam) first.
glob TYPE_RULES: list[tuple[str, list[str], str]] = [
    ("exam", ["exam", "quiz"], "#F28C28"),      # orange
    ("project", ["project"], "#2F6FDE"),        # blue: work daily / challenge deadline
    ("optional", ["optional"], "#8E4EC6")       # purple
];

# Urgency tiers by days left. Overdue (< 0) is treated as red too.
glob URGENCY_COLORS: dict[str, str] = {
    "overdue": "#B3261E",
    "urgent": "#E5383B",      # red: 0-1 days
    "soon": "#FFCB05",        # maize: 2-7 days
    "upcoming": "#8FD3F4",    # light blue: 8-14 days
    "later": ""               # no highlight: 15+ days
};

# ---------------------------------------------------------------- graph

node category_root {
    has subject: str,       # the spreadsheet's Subject, e.g. "STATS 250"
        kind: str = "coursework";   # coursework | job_search | clubs
}

node task {
    has subject: str,
        assignment_name: str,
        status: str = "Not started",
        due_date: str = "",         # ISO yyyy-mm-dd ("" = no due date)
        created_at: str = "";
}

edge task_edge: category_root --> task {
    has added_on: str = "";
}

# What every walker reports: the stored task plus the computed, display-ready
# fields, so all three clients apply exactly the same highlight rules.
obj TaskView {
    has id: str,
        subject: str,
        category: str,
        assignment_name: str,
        status: str,
        due_date: str,
        due_label: str,
        days_left: int,
        has_due: bool,
        type_tag: str,
        type_color: str,
        urgency: str,
        urgency_color: str,
        is_open: bool;
}

obj NotificationFeed {
    has overdue: list[TaskView] = [],
        due_now: list[TaskView] = [],     # 0-1 days left
        exams: list[TaskView] = [],       # open exams/quizzes within exam_window
        count: int = 0,
        generated_on: str = "";
}

# ---------------------------------------------------------------- rules
# Underscore-prefixed helpers stay off the REST API.

def _today -> date {
    return date.today();
}

def _category_kind(subject: str) -> str {
    s = subject.lower();
    if "job" in s or "j*b" in s or "career" in s or "recruit" in s {
        return "job_search";
    }
    if "club" in s {
        return "clubs";
    }
    return "coursework";
}

"""Accept 2026-09-30, 9/30, 9/30/2026, 'Wednesday, 9/30', today, tomorrow, +3, -2."""
def _parse_due(raw: str) -> str {
    s = raw.strip().lower();
    if not s {
        return "";
    }
    today = _today();
    if s == "today" {
        return today.isoformat();
    }
    if s == "tomorrow" {
        return (today + timedelta(days=1)).isoformat();
    }
    if s[0] in "+-" and s[1:].isdigit() {
        return (today + timedelta(days=int(s))).isoformat();   # +3 / -2 days
    }
    if "," in s {
        s = s.split(",")[-1].strip();     # drop the weekday: "wednesday, 9/30"
    }
    try {
        return datetime.strptime(s, "%Y-%m-%d").date().isoformat();
    } except ValueError {}
    parts = s.split("/");
    if len(parts) in [2, 3] and all([p.isdigit() for p in parts]) {
        try {
            if len(parts) == 3 {
                year = int(parts[2]);
                return date(year + 2000 if year < 100 else year, int(parts[0]), int(parts[1])).isoformat();
            }
            # No year given: this year, unless that is months ago
            # ("1/15" typed in December means next January).
            d = date(today.year, int(parts[0]), int(parts[1]));
            if (today - d).days > 150 {
                d = date(today.year + 1, d.month, d.day);
            }
            return d.isoformat();
        } except ValueError {}
    }
    raise ValueError(f"Unrecognized due date '{raw}'. Try 9/30, 2026-09-30, today or +3.");
}

def _due_label(iso: str) -> str {
    if not iso {
        return "No due date";
    }
    d = date.fromisoformat(iso);
    return f"{d.strftime('%A')}, {d.month}/{d.day}";     # "Wednesday, 9/30"
}

def _days_left(iso: str) -> int {
    if not iso {
        return 9999;
    }
    return (date.fromisoformat(iso) - _today()).days;
}

def _type_tag(assignment_name: str) -> tuple[str, str] {
    name = assignment_name.lower();
    for (tag, words, color) in TYPE_RULES {
        for w in words {
            if w in name {
                return (tag, color);
            }
        }
    }
    return ("", "");
}

def _urgency(days_left: int) -> str {
    if days_left < 0 {
        return "overdue";
    }
    if days_left <= 1 {
        return "urgent";
    }
    if days_left <= 7 {
        return "soon";
    }
    if days_left <= 14 {
        return "upcoming";
    }
    return "later";
}

def _view(t: task) -> TaskView {
    days = _days_left(t.due_date);
    (tag, tcolor) = _type_tag(t.assignment_name);
    urg = _urgency(days) if t.due_date else "later";
    return TaskView(
        id=jid(t),
        subject=t.subject,
        category=_category_kind(t.subject),
        assignment_name=t.assignment_name,
        status=t.status,
        due_date=t.due_date,
        due_label=_due_label(t.due_date),
        days_left=days if t.due_date else 0,
        has_due=bool(t.due_date),
        type_tag=tag,
        type_color=tcolor,
        urgency=urg,
        urgency_color=URGENCY_COLORS[urg],
        is_open=t.status not in CLOSED_STATUSES
    );
}

def _sort_key(v: TaskView) -> tuple[int, int, str] {
    # open first, then soonest due, then name
    return (0 if v.is_open else 1, v.days_left if v.has_due else 99999, v.assignment_name);
}

"""Drop subjects that no longer have any tasks (after a move or delete)."""
def _prune_empty_categories {
    for c in [root-->[?:category_root]] {
        if len([c->:task_edge:->]) == 0 {
            del c;
        }
    }
}

def _check_status(status: str) -> str {
    for s in STATUSES {
        if s.lower() == status.strip().lower() {
            return s;
        }
    }
    raise ValueError(f"Status must be one of {STATUSES}, got '{status}'.");
}

# ---------------------------------------------------------------- create

walker:pub add_task {
    has subject: str,
        assignment_name: str,
        due_date: str = "",
        status: str = "Not started",
        reports: list[TaskView] = [];

    can find_category with Root entry {
        subj = self.subject.strip();
        self.status = _check_status(self.status);
        self.due_date = _parse_due(self.due_date);
        # get-or-create the subject's category_root, then continue into it
        visit [here-->[?:category_root, subject == subj]] else {
            fresh = here ++> category_root(subject=subj, kind=_category_kind(subj));
            visit fresh;
        }
    }

    can create with category_root entry {
        now = datetime.now().isoformat(timespec="seconds");
        created = here +>:task_edge(added_on=now):+> task(
            subject=here.subject,
            assignment_name=self.assignment_name.strip(),
            status=self.status,
            due_date=self.due_date,
            created_at=now
        );
        report _view(created[0]);
    }
}

# ---------------------------------------------------------------- read

walker:pub get_tasks {
    """All tasks, optionally filtered. Every filter is optional.

    subject   case-insensitive substring of the subject ("math", "job")
    category  coursework | job_search | clubs
    status    exact status, or "open" for Not started + In progress
    urgency   overdue | urgent | soon | upcoming | later
    due_date  one day (any accepted date format, e.g. "today")
    max_days  only tasks due within N days (e.g. 1 = the "today" view)
    """
    has subject: str = "",
        category: str = "",
        status: str = "",
        urgency: str = "",
        due_date: str = "",
        max_days: int = -1,
        include_closed: bool = True,
        found: list[TaskView] = [],
        reports: list[TaskView] = [];

    can start with Root entry {
        self.due_date = _parse_due(self.due_date);
        visit [-->[?:category_root]];
    }

    can in_category with category_root entry {
        if self.subject and self.subject.lower() not in here.subject.lower() {
            skip;
        }
        if self.category and here.kind != self.category {
            skip;
        }
        visit [->:task_edge:->];
    }

    can collect with task entry {
        v = _view(here);
        if self.status == "open" and not v.is_open { skip; }
        if self.status and self.status != "open" and v.status.lower() != self.status.lower() { skip; }
        if not self.include_closed and not v.is_open { skip; }
        if self.urgency and v.urgency != self.urgency { skip; }
        if self.due_date and v.due_date != self.due_date { skip; }
        if self.max_days >= 0 and (not v.has_due or v.days_left > self.max_days) { skip; }
        self.found.append(v);
    }

    can finish with Root exit {
        for v in sorted(self.found, key=_sort_key) {
            report v;
        }
    }
}

walker:pub get_subjects {
    """Distinct subjects (category_root names) for filter dropdowns."""
    has reports: list[category_root] = [];

    can list_them with Root entry {
        for c in sorted([-->[?:category_root]], key=lambda c: category_root : c.subject.lower()) {
            report c;
        }
    }
}

"""Open items that need attention: overdue, due in 0-1 days, and
exams/quizzes coming up within `exam_window` days."""
walker:pub get_notifications {
    has exam_window: int = 14,
        overdue: list[TaskView] = [],
        due_now: list[TaskView] = [],
        exams: list[TaskView] = [],
        reports: list[NotificationFeed] = [];

    can start with Root entry {
        visit [-->[?:category_root]->:task_edge:->];
    }

    can check with task entry {
        v = _view(here);
        if not v.is_open or not v.has_due {
            skip;
        }
        if v.days_left < 0 {
            self.overdue.append(v);
        } elif v.days_left <= 1 {
            self.due_now.append(v);
        }
        if v.type_tag == "exam" and 0 <= v.days_left <= self.exam_window {
            self.exams.append(v);
        }
    }

    can finish with Root exit {
        # Build the feed here rather than as an object default on `has`:
        # an object default would be shared by every request and keep growing.
        feed = NotificationFeed(
            overdue=sorted(self.overdue, key=_sort_key),
            due_now=sorted(self.due_now, key=_sort_key),
            exams=sorted(self.exams, key=_sort_key)
        );
        ids: list[str] = [];
        for group in [feed.overdue, feed.due_now, feed.exams] {
            for v in group {
                if v.id not in ids {
                    ids.append(v.id);
                }
            }
        }
        feed.count = len(ids);
        feed.generated_on = _today().isoformat();
        report feed;
    }
}

# ---------------------------------------------------------------- update / delete
# Lookup-base walker: resolve the task id once, then subclasses act on it.

walker:pub task_lookup {
    has task_id: str = "",
        reports: list[TaskView] = [];

    can locate with Root entry {
        target: any = None;
        try {
            target = jobj(self.task_id.strip());
        } except Exception {}
        if isinstance(target, task) {
            visit [target];
        } else {
            raise ValueError(f"No task with id '{self.task_id}'.");
        }
    }
}

walker:pub update_task_status(task_lookup) {
    has status: str = "Done";

    can set_status with task entry {
        here.status = _check_status(self.status);
        report _view(here);
        disengage;
    }
}

walker:pub update_task(task_lookup) {
    """Inline edit. Empty fields are left unchanged. Changing the subject
    moves the task under the matching category_root."""
    has subject: str = "",
        assignment_name: str = "",
        due_date: str = "",
        status: str = "",
        clear_due: bool = False;

    can edit with task entry {
        if self.assignment_name.strip() {
            here.assignment_name = self.assignment_name.strip();
        }
        if self.status {
            here.status = _check_status(self.status);
        }
        if self.clear_due {
            here.due_date = "";
        } elif self.due_date.strip() {
            here.due_date = _parse_due(self.due_date);
        }
        new_subj = self.subject.strip();
        if new_subj and new_subj != here.subject {
            for e in [edge here <-:task_edge:<-] {
                del e;
            }
            cats = [root-->[?:category_root, subject == new_subj]];
            cat = cats[0] if cats else (root ++> category_root(subject=new_subj, kind=_category_kind(new_subj)))[0];
            cat +>:task_edge(added_on=datetime.now().isoformat(timespec="seconds")):+> here;
            here.subject = new_subj;
            _prune_empty_categories();
        }
        report _view(here);
        disengage;
    }
}

walker:pub delete_task(task_lookup) {
    can remove with task entry {
        gone = _view(here);
        del here;
        _prune_empty_categories();
        report gone;
        disengage;
    }
}
