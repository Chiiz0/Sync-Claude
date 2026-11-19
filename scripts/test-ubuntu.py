"""Installed-package smoke test. Run under Xvfb in a disposable D-Bus session."""
import json
import os
import runpy
import subprocess
import tempfile
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib


def check_install(home):
    config = home / "config"
    environment = {"HOME": str(home), "XDG_CONFIG_HOME": str(config),
                   "XDG_DATA_HOME": str(home / "data"), "XDG_RUNTIME_DIR": str(home / "run"),
                   "GSETTINGS_BACKEND": "memory"}
    (home / "run").mkdir(mode=0o700)
    os.environ.update(environment)

    def cli(*arguments):
        return subprocess.check_output(["sync-claude", *arguments], text=True)

    session = "11111111-1111-4111-8111-111111111111"
    owner = "22222222-2222-4222-8222-222222222222"
    org = "33333333-3333-4333-8333-333333333333"
    directory = config / "Claude" / "claude-code-sessions" / owner / org
    directory.mkdir(parents=True)
    record = directory / f"local_{session}.json"
    record.write_text(json.dumps({"sessionId": "local_" + session, "cliSessionId": session,
                                  "cwd": str(home), "title": "Ubuntu fixture"}))
    project = home / ".claude/projects/test"
    project.mkdir(parents=True)
    (project / f"{session}.jsonl").write_text('{"type":"user"}\n')

    assert "--status" in cli("--help")
    status = json.loads(cli("--status"))
    assert status["statePath"] == str(config / "SyncClaude")
    assert status["sessions"][0]["transcriptAvailable"]
    cli("--archive")
    index = config / "SyncClaude/history/index.json"
    assert "local_" + session in json.loads(index.read_text())
    assert index.stat().st_mode & 0o777 == 0o600
    cli("--compact-history")

    subprocess.run(["gnome-keyring-daemon", "--unlock", "--components=secrets"],
                   input=b"fixture-only", stdout=subprocess.DEVNULL, check=True)
    cli("--self-test-keychain")
    subprocess.run(["desktop-file-validate", "/usr/share/applications/com.syncclaude.desktop.desktop"], check=True)

    # Start the installed GTK application and wait for its actual CLI response.
    app = runpy.run_path("/usr/lib/sync-claude/window.py", run_name="syncclaude")["App"](application_id="com.syncclaude.test")
    errors = []

    def check_window():
        window = app.get_active_window()
        if window is None or window.busy:
            return True
        if len(window.sessions) != 1 or window.sessions[0][0] != "Ubuntu fixture":
            errors.append(window.feedback.get_text() or "Session list not populated")
        app.quit()
        return False

    def timed_out():
        errors.append("GTK status refresh timed out")
        app.quit()
        return False

    GLib.timeout_add(50, check_window)
    GLib.timeout_add_seconds(20, timed_out)
    app.run([])
    assert not errors, errors


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="sync-claude-test-") as directory:
        check_install(Path(directory))
    print("Installed CLI, archive, Secret Service and GTK smoke tests passed.")
