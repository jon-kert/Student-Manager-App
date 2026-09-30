"""Task Planner - mobile check-in (iOS-first, wrapped by Capacitor).

Two tabs: Today (overdue + due in 0-1 days, plus the rest of the week) and
Alerts, the notification center. Alerts come from the server's
get_notifications walker; dismissing one is a per-device choice kept in
localStorage and reset each day, so nothing is hidden for long.
"""

import from react { useEffect }

sv import from server {
    TaskView, NotificationFeed, get_notifications, get_tasks, update_task_status
}

obj Alert {
    has task: TaskView,
        reason: str;
}

def days_phrase(t: TaskView) -> str {
    if t.days_left < 0 {
        return str(0 - t.days_left) + (" day late" if t.days_left == -1 else " days late");
    }
    if t.days_left == 0 {
        return "Due today";
    }
    return "Due tomorrow" if t.days_left == 1 else "Due in " + str(t.days_left) + " days";
}

def build_alerts(feed: NotificationFeed | None) -> list[Alert] {
    if feed is None {
        return [];
    }
    seen: list[str] = [];
    out: list[Alert] = [];
    for t in feed.overdue {
        out.append(Alert(task=t, reason="Overdue"));
        seen.append(t.id);
    }
    for t in feed.due_now {
        out.append(Alert(task=t, reason="Due today" if t.days_left == 0 else "Due tomorrow"));
        seen.append(t.id);
    }
    for t in feed.exams {
        if t.id not in seen {
            out.append(Alert(task=t, reason="Exam or quiz in " + str(t.days_left) + " days"));
        }
    }
    return out;
}

def:pub TaskCard(
    t: TaskView, busy: bool, onStatus: Callable[[str, str], None]
) -> JsxElement {
    is_exam = t.type_tag == "exam";
    urgent_ink = "#FFFFFF" if t.urgency in ["urgent", "overdue"] else "#14213D";
    return <article
        className={"mb-card" + (" is-exam" if is_exam else "") + ("" if t.is_open else " is-closed")}
        style={{"borderLeftColor": t.type_color or "#D5DAE3"}}>
        <div className="mb-card-top">
            <span className="mb-subject">{t.subject}</span>
            {t.urgency_color and t.is_open and
                <span className="mb-pill" style={{"background": t.urgency_color, "color": urgent_ink}}>
                    {days_phrase(t)}
                </span>}
        </div>
        <h3 className="mb-title">{t.assignment_name}</h3>
        <p className="mb-meta">{t.due_label + ", " + t.status.lower()}</p>
        <div className="mb-actions">
            <button className="mb-btn mb-done" disabled={busy or t.status == "Done"}
                onClick={lambda { onStatus(t.id, "Done"); }}>Done</button>
            <button className="mb-btn" disabled={busy or t.status == "In progress"}
                onClick={lambda { onStatus(t.id, "In progress"); }}>In progress</button>
        </div>
    </article>;
}

def:pub MobileApp(onSwitch: Callable[[], None]) -> JsxElement {
    has feed: NotificationFeed | None = None,
        week: list[TaskView] = [],
        tab: str = "today",
        dismissed: list[str] = [],
        busyId: str = "",
        error: str = "",
        loaded: bool = False;

    async def refresh {
        try {
            n = root spawn get_notifications();
            feed = n.reports[0] if len(n.reports) > 0 else None;
            w = root spawn get_tasks(max_days=7, status="open");
            week = [t for t in w.reports if t.days_left >= 2];
            error = "";
        } except Exception as e {
            error = "Offline: can't reach the planner server.";
            console.log("[mobile] refresh failed", e);
        }
        loaded = True;
    }

    # Initial load + a light 60s poll so the badge stays current.
    useEffect(lambda {
        refresh();
        timer = setInterval(lambda { refresh(); }, 60000);
        return lambda { clearInterval(timer); };
    }, []);

    # Per-device dismissals, keyed by the feed's date so they reset daily.
    storage_key = "taskplanner.dismissed." + (feed.generated_on if feed is not None else "");
    can with [storage_key] entry {
        raw = localStorage.getItem(storage_key);
        dismissed = (JSON.parse(raw) as list[str]) if raw else [];  # jac:ignore[W6002]
    }

    def save_dismissed(ids: list[str]) {
        dismissed = ids;
        localStorage.setItem(storage_key, JSON.stringify(ids));  # jac:ignore[W6002]
    }

    async def setStatus(taskId: str, status: str) {
        busyId = taskId;
        try {
            root spawn update_task_status(task_id=taskId, status=status);
            await refresh();
        } except Exception {
            error = "Couldn't update that task. Try again.";
        }
        busyId = "";
    }

    alerts = build_alerts(feed);
    live_alerts = [a for a in alerts if a.task.id not in dismissed];
    now_items = (feed.overdue + feed.due_now) if feed is not None else [];
    now_ids = [t.id for t in now_items];
    # Exams already shown under "Due now" (tinted orange there) aren't repeated.
    exams = [t for t in feed.exams if t.id not in now_ids] if feed is not None else [];
    exam_ids = [t.id for t in exams];
    week_items = [t for t in week if t.id not in exam_ids];

    return <div className="mb">
        <header className="mb-head">
            <div>
                <p className="mb-date">{new(Date).toLocaleDateString("en-US", {"weekday": "long", "month": "long", "day": "numeric"})}</p>
                <h1>{"All clear" if len(now_items) == 0 else str(len(now_items)) + " due now"}</h1>
            </div>
            <button className="mb-bell" aria-label={str(len(live_alerts)) + " alerts"}
                onClick={lambda { tab = "alerts"; }}>
                <span className="mb-bell-icon" aria-hidden="true"></span>
                {len(live_alerts) > 0 and <span className="mb-badge">{len(live_alerts)}</span>}
            </button>
        </header>

        <nav className="mb-tabs" role="tablist">
            <button role="tab" aria-selected={tab == "today"} className={"is-on" if tab == "today" else ""}
                onClick={lambda { tab = "today"; }}>Today</button>
            <button role="tab" aria-selected={tab == "alerts"} className={"is-on" if tab == "alerts" else ""}
                onClick={lambda { tab = "alerts"; }}>
                {"Alerts" + (" (" + str(len(live_alerts)) + ")" if len(live_alerts) > 0 else "")}
            </button>
        </nav>

        {error and <p className="mb-error" role="alert">{error}</p>}
        {not loaded and <p className="mb-empty">Loading…</p>}

        {if loaded and tab == "today" {
            <section key="today" className="mb-section">
                <h2>Due now</h2>
                {if len(now_items) == 0 {
                    <p className="mb-empty">Nothing due today or tomorrow.</p>
                }}
                {for t in now_items {
                    <TaskCard key={t.id} t={t} busy={busyId == t.id} onStatus={setStatus} />
                }}

                {if len(exams) > 0 {
                    <h2 className="mb-exam-head">Exams and quizzes ahead</h2>
                    for t in exams {
                        <TaskCard key={"x" + t.id} t={t} busy={busyId == t.id} onStatus={setStatus} />
                    }
                }}

                <h2>Later this week</h2>
                {if len(week_items) == 0 {
                    <p className="mb-empty">Nothing else in the next 7 days.</p>
                }}
                {for t in week_items {
                    <TaskCard key={"w" + t.id} t={t} busy={busyId == t.id} onStatus={setStatus} />
                }}
            </section>
        }}

        {if loaded and tab == "alerts" {
            <section key="alerts" className="mb-section">
                <div className="mb-alerts-bar">
                    <h2>Notification center</h2>
                    {if len(live_alerts) > 0 {
                        <button className="mb-text-btn"
                            onClick={lambda { save_dismissed([a.task.id for a in alerts]); }}>Clear all</button>
                    } elif len(dismissed) > 0 {
                        <button className="mb-text-btn" onClick={lambda { save_dismissed([]); }}>Show dismissed</button>
                    }}
                </div>
                {if len(live_alerts) == 0 {
                    <p className="mb-empty">You're caught up.</p>
                }}
                {for a in live_alerts {
                    <div key={"a" + a.task.id}
                        className={"mb-alert" + (" is-exam" if a.task.type_tag == "exam" else "")}>
                        <div className="mb-alert-row">
                            <span className="mb-reason">{a.reason}</span>
                            <button className="mb-x" aria-label="Dismiss"
                                onClick={lambda { save_dismissed(dismissed + [a.task.id]); }}>×</button>
                        </div>
                        <TaskCard t={a.task} busy={busyId == a.task.id} onStatus={setStatus} />
                    </div>
                }}
            </section>
        }}

        <footer className="mb-foot">
            <button className="mb-text-btn" onClick={lambda { onSwitch(); }}>Open full task sheet</button>
        </footer>
    </div>;
}
