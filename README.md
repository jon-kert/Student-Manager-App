# Task Planner

One Jac server shared by three interfaces: a web task sheet, a mobile check-in with a notification center, and a terminal CLI.

| File | What it is |
|---|---|
| `server.jac` | Graph model (`category_root → task_edge → task`), highlight rules, CRUD walkers |
| `web_app.cl.jac` | Web dashboard: filterable sheet, inline add/edit, job search summary |
| `mobile_app.cl.jac` | Mobile check-in: due now, exams, notification center, quick actions |
| `cli.jac` | Terminal client: `add`, `today`, `done`, `start`, `skip`, `list`, `notify` |
| `main.jac` | Entry point that serves the API, web app (`/`) and mobile app (`/m`) |
| `global.css`, `jac.toml` | Styles and project config |

## Highlight rules

Type (by assignment name, checked in this order): Exam/Quiz is orange, Project is blue, Optional is purple.
Urgency (by days left): overdue is dark red, 0–1 days red, 2–7 days maize, 8–14 days light blue.

## Setup

Requires Python 3.12+ and [Bun](https://bun.sh).

```bash
pip install jaclang jac-client jac-scale
jac start main.jac          # web: http://localhost:8000   mobile: http://localhost:8000/m
```

## CLI

Run while the server is up (set `TASKPLANNER_URL` if it isn't on localhost:8000).

```bash
jac run cli.jac add "MATH 417" "Midterm Exam 1" "Wednesday, 10/7"
jac run cli.jac today        # overdue + due today/tomorrow; `today 7` for a week
jac run cli.jac done 450e6b  # first 6 characters of the id are enough
jac run cli.jac notify
```

Due dates accept `9/30`, `Wednesday, 9/30`, `2026-09-30`, `today`, `tomorrow`, or `+3`.

## iOS app

On macOS with Xcode:

```bash
jac setup mobile --platform ios
jac start main.jac --client mobile --dev
```

The native app is a frontend only, so deploy the server somewhere reachable first.

## Data

Tasks persist in `.jac/data/` (git-ignored). To reset, stop the server and delete that folder.

Walkers are `walker:pub`, so all clients share one graph without logging in. Before deploying publicly, remove `:pub` and add login.
