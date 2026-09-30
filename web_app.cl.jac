"""Task Planner - web dashboard: the full task sheet + job search pipeline.

Every read/write spawns a server walker; the server computes days-left,
type highlight and urgency tier, so this file only paints what it receives.
"""

sv import from server {
    TaskView, category_root,
    add_task, get_tasks, get_subjects, update_task_status, update_task, delete_task
}

glob STATUSES: list[str] = ["Not started", "In progress", "Done", "Skipped"];
glob CATEGORIES: list[tuple[str, str]] = [
    ("", "Everything"), ("coursework", "Coursework"), ("job_search", "Job search"), ("clubs", "Clubs")
];
glob URGENCY_OPTIONS: list[tuple[str, str]] = [
    ("", "Any urgency"), ("overdue", "Overdue"), ("urgent", "0-1 days"),
    ("soon", "2-7 days"), ("upcoming", "8-14 days"), ("later", "15+ days")
];

def days_text(t: TaskView) -> str {
    if not t.has_due {
        return "-";
    }
    if t.days_left < 0 {
        return str(0 - t.days_left) + "d late";
    }
    if t.days_left == 0 {
        return "Today";
    }
    return "1 day" if t.days_left == 1 else str(t.days_left) + " days";
}

def urgency_style(t: TaskView) -> dict[str, str] {
    if not t.urgency_color or not t.is_open {
        return {};
    }
    ink = "#FFFFFF" if t.urgency in ["urgent", "overdue"] else "#14213D";
    return {"background": t.urgency_color, "color": ink};
}

def type_style(t: TaskView) -> dict[str, str] {
    if not t.type_color {
        return {};
    }
    return {"background": t.type_color + "1F", "boxShadow": "inset 4px 0 0 " + t.type_color};
}

def:pub PipelineCard(
    label: str, rows: list[TaskView], active: bool, onPick: Callable[[], None]
) -> JsxElement {
    open_rows = [r for r in rows if r.is_open];
    nxt = open_rows[0] if len(open_rows) > 0 else None;
    return <button className={"ws-pipe" + (" is-active" if active else "")} onClick={lambda { onPick(); }}>
        <span className="ws-pipe-label">{label}</span>
        <span className="ws-pipe-counts">
            {for s in STATUSES {
                <span key={s} className="ws-pipe-count">
                    <strong>{len([r for r in rows if r.status == s])}</strong>{" " + s.lower()}
                </span>
            }}
        </span>
        <span className="ws-pipe-next">
            {("Next: " + nxt.assignment_name + ", " + nxt.due_label) if nxt else "Nothing open"}
        </span>
    </button>;
}

def:pub WebApp(onSwitch: Callable[[], None]) -> JsxElement {
    has tasks: list[TaskView] = [],
        everything: list[TaskView] = [],
        subjects: list[str] = [],
        category: str = "",
        subjectFilter: str = "",
        statusFilter: str = "",
        urgencyFilter: str = "",
        hideClosed: bool = False,
        newSubject: str = "",
        newName: str = "",
        newDue: str = "",
        newStatus: str = "Not started",
        editingId: str = "",
        editSubject: str = "",
        editName: str = "",
        editDue: str = "",
        error: str = "",
        loading: bool = True;

    async def refresh {
        try {
            filtered = root spawn get_tasks(
                category=category, subject=subjectFilter, status=statusFilter,
                urgency=urgencyFilter, include_closed=not hideClosed
            );
            tasks = filtered.reports;
            full = root spawn get_tasks();
            everything = full.reports;
            subs = root spawn get_subjects();
            subjects = [c.subject for c in subs.reports];
            error = "";
        } except Exception as e {
            error = "Couldn't reach the planner server: " + str(e);
        }
        loading = False;
    }

    async can with (category, subjectFilter, statusFilter, urgencyFilter, hideClosed) entry {
        await refresh();
    }

    async def addTask -> None {
        if not newSubject.strip() or not newName.strip() {
            error = "A new row needs a subject and an assignment name.";
            return;
        }
        try {
            root spawn add_task(
                subject=newSubject, assignment_name=newName, due_date=newDue, status=newStatus
            );
            newName = "";
            newDue = "";
            newStatus = "Not started";
            await refresh();
        } except Exception as e {
            error = str(e);
        }
    }

    async def setStatus(taskId: str, status: str) {
        try {
            root spawn update_task_status(task_id=taskId, status=status);
            await refresh();
        } except Exception as e {
            error = str(e);
        }
    }

    def startEdit(t: TaskView) {
        editingId = t.id;
        editSubject = t.subject;
        editName = t.assignment_name;
        editDue = t.due_date;
    }

    async def saveEdit {
        try {
            root spawn update_task(
                task_id=editingId, subject=editSubject, assignment_name=editName,
                due_date=editDue, clear_due=(editDue.strip() == "")
            );
            editingId = "";
            await refresh();
        } except Exception as e {
            error = str(e);
        }
    }

    async def removeTask(taskId: str) -> None {
        if not window.confirm("Delete this row?") {
            return;
        }
        root spawn delete_task(task_id=taskId);
        await refresh();
    }

    def onNewKey(e: KeyboardEvent) {
        if e.key == "Enter" {
            addTask();
        }
    }

    def onEditKey(e: KeyboardEvent) {
        if e.key == "Enter" {
            saveEdit();
        }
        if e.key == "Escape" {
            editingId = "";
        }
    }

    urgent_count = len([t for t in everything if t.is_open and t.has_due and t.days_left <= 1]);
    week_count = len([t for t in everything if t.is_open and t.urgency == "soon"]);
    coursework = [t for t in everything if t.category == "coursework"];
    job_search = [t for t in everything if t.category == "job_search"];

    return <div className="ws">
        <header className="ws-head">
            <div>
                <h1>Task sheet</h1>
                <p className="ws-sub">
                    {str(urgent_count) + " due within a day, " + str(week_count) + " more this week"}
                </p>
            </div>
            <button className="ws-link" onClick={lambda { onSwitch(); }}>
                Open mobile check-in
            </button>
        </header>

        <section className="ws-pipeline">
            <PipelineCard label="Coursework" rows={coursework} active={category == "coursework"}
                onPick={lambda { category = "" if category == "coursework" else "coursework"; }} />
            <PipelineCard label="Job search" rows={job_search} active={category == "job_search"}
                onPick={lambda { category = "" if category == "job_search" else "job_search"; }} />
        </section>

        <section className="ws-filters">
            <div className="ws-seg" role="tablist">
                {for (value, label) in CATEGORIES {
                    <button key={label} role="tab" aria-selected={category == value}
                        className={"is-on" if category == value else ""}
                        onClick={lambda { category = value; }}>{label}</button>
                }}
            </div>
            <select value={subjectFilter} onChange={lambda e: ChangeEvent { subjectFilter = e.target.value; }}>
                <option value="">All subjects</option>
                {for s in subjects { <option key={s} value={s}>{s}</option> }}
            </select>
            <select value={statusFilter} onChange={lambda e: ChangeEvent { statusFilter = e.target.value; }}>
                <option value="">Any status</option>
                <option value="open">Open (not done)</option>
                {for s in STATUSES { <option key={s} value={s}>{s}</option> }}
            </select>
            <select value={urgencyFilter} onChange={lambda e: ChangeEvent { urgencyFilter = e.target.value; }}>
                {for (value, label) in URGENCY_OPTIONS { <option key={label} value={value}>{label}</option> }}
            </select>
            <label className="ws-check">
                <input type="checkbox" checked={hideClosed}
                    onChange={lambda e: ChangeEvent { hideClosed = e.target.checked; }} />
                Hide done and skipped
            </label>
        </section>

        {error and <p className="ws-error" role="alert">{error}</p>}

        <div className="ws-table-wrap">
            <table className="ws-table">
                <thead>
                    <tr>
                        <th>Subject</th><th>Assignment</th><th>Status</th>
                        <th>Due</th><th className="ws-num">Days left</th><th></th>
                    </tr>
                </thead>
                <tbody>
                    <tr className="ws-new">
                        <td>
                            <input list="ws-subjects" placeholder="Subject" value={newSubject}
                                onChange={lambda e: ChangeEvent { newSubject = e.target.value; }}
                                onKeyDown={onNewKey} />
                            <datalist id="ws-subjects">
                                {for s in subjects { <option key={s} value={s} /> }}
                            </datalist>
                        </td>
                        <td>
                            <input placeholder="New assignment, e.g. Midterm Exam 2" value={newName}
                                onChange={lambda e: ChangeEvent { newName = e.target.value; }}
                                onKeyDown={onNewKey} />
                        </td>
                        <td>
                            <select value={newStatus} onChange={lambda e: ChangeEvent { newStatus = e.target.value; }}>
                                {for s in STATUSES { <option key={s} value={s}>{s}</option> }}
                            </select>
                        </td>
                        <td>
                            <input placeholder="9/30, +3, today" value={newDue}
                                onChange={lambda e: ChangeEvent { newDue = e.target.value; }}
                                onKeyDown={onNewKey} />
                        </td>
                        <td></td>
                        <td><button className="ws-btn" onClick={lambda { addTask(); }}>Add</button></td>
                    </tr>

                    {if loading {
                        <tr key="loading"><td colSpan={6} className="ws-empty">Loading the sheet…</td></tr>
                        skip;
                    }}
                    {if len(tasks) == 0 {
                        <tr key="empty"><td colSpan={6} className="ws-empty">No rows match these filters.</td></tr>
                        skip;
                    }}
                    {for t in tasks {
                        if t.id == editingId {
                            <tr key={t.id} className="ws-editing">
                                <td><input value={editSubject} onKeyDown={onEditKey}
                                    onChange={lambda e: ChangeEvent { editSubject = e.target.value; }} /></td>
                                <td><input value={editName} onKeyDown={onEditKey}
                                    onChange={lambda e: ChangeEvent { editName = e.target.value; }} /></td>
                                <td>{t.status}</td>
                                <td><input value={editDue} placeholder="blank = no date" onKeyDown={onEditKey}
                                    onChange={lambda e: ChangeEvent { editDue = e.target.value; }} /></td>
                                <td></td>
                                <td className="ws-actions">
                                    <button className="ws-btn" onClick={lambda { saveEdit(); }}>Save</button>
                                    <button className="ws-ghost" onClick={lambda { editingId = ""; }}>Cancel</button>
                                </td>
                            </tr>
                        } else {
                            <tr key={t.id} className={"" if t.is_open else "is-closed"}>
                                <td className="ws-subject">{t.subject}</td>
                                <td style={type_style(t)} className="ws-name"
                                    onDoubleClick={lambda { startEdit(t); }}>
                                    {t.assignment_name}
                                </td>
                                <td>
                                    <select className="ws-status" value={t.status}
                                        onChange={lambda e: ChangeEvent { setStatus(t.id, e.target.value); }}>
                                        {for s in STATUSES { <option key={s} value={s}>{s}</option> }}
                                    </select>
                                </td>
                                <td>{t.due_label}</td>
                                <td className="ws-num ws-days" style={urgency_style(t)}>{days_text(t)}</td>
                                <td className="ws-actions">
                                    <button className="ws-ghost" onClick={lambda { startEdit(t); }}>Edit</button>
                                    <button className="ws-ghost" aria-label="Delete row"
                                        onClick={lambda { removeTask(t.id); }}>×</button>
                                </td>
                            </tr>
                        }
                    }}
                </tbody>
            </table>
        </div>

        <footer className="ws-legend">
            <span><span className="ws-swatch" style={{"background": "#F28C28"}}></span>Exam or quiz</span>
            <span><span className="ws-swatch" style={{"background": "#2F6FDE"}}></span>Project, work on it daily</span>
            <span><span className="ws-swatch" style={{"background": "#8E4EC6"}}></span>Optional</span>
            <span className="ws-gap"><span className="ws-swatch" style={{"background": "#E5383B"}}></span>0-1 days</span>
            <span><span className="ws-swatch" style={{"background": "#FFCB05"}}></span>2-7 days</span>
            <span><span className="ws-swatch" style={{"background": "#8FD3F4"}}></span>8-14 days</span>
        </footer>
    </div>;
}
