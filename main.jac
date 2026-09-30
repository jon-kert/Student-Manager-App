"""Task Planner - entry point.

`jac start main.jac` serves everything from one process:
  /walker/*   the REST API (server.jac) used by all three clients
  /           the web dashboard (web_app.cl.jac)
  /m          the mobile check-in (mobile_app.cl.jac); also the default view
              inside the Capacitor iOS/Android shell
"""

# Importing the walkers registers them all, including ones only the CLI uses.
import from server {
    task, category_root, task_edge, TaskView, NotificationFeed,
    add_task, get_tasks, get_subjects, get_notifications,
    update_task_status, update_task, delete_task
}

cl {
    import "./global.css";
    import from .web_app { WebApp }
    import from .mobile_app { MobileApp }

    def opens_mobile -> bool {
        w: any = window;    # Capacitor injects window.Capacitor into the native shell
        return str(w.location.pathname).startswith("/m") or bool(w.Capacitor);
    }

    def:pub app -> JsxElement {
        has mobile: bool = opens_mobile();

        def switch_view {
            window.history.pushState({}, "", "/" if mobile else "/m");
            mobile = not mobile;
        }

        return <MobileApp onSwitch={switch_view} /> if mobile else <WebApp onSwitch={switch_view} />;
    }
}
