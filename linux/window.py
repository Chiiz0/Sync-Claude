#!/usr/bin/python3
import json
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk

CORE = Path(__file__).resolve().with_name("SyncClaude")


def button(label, action):
    widget = Gtk.Button.new_with_label(label)
    widget.connect("clicked", lambda _: action())
    return widget


def table(columns):
    rows = Gtk.ListStore(*([str] * len(columns)))
    view = Gtk.TreeView(model=rows)
    for index, name in enumerate(columns):
        if name:
            column = Gtk.TreeViewColumn(name, Gtk.CellRendererText(), text=index)
            column.set_resizable(True)
            view.append_column(column)
    scroller = Gtk.ScrolledWindow()
    scroller.add(view)
    return rows, view, scroller


class Window(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Sync Claude")
        self.set_default_size(800, 560)
        self.set_border_width(16)
        self.status = {}
        self.busy = False
        self.closed = False
        self.connect("destroy", self.on_destroy)
        self.connect("delete-event", lambda *_: self.busy)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.add(outer)
        header = Gtk.HeaderBar(title="Sync Claude", show_close_button=True)
        self.set_titlebar(header)
        self.refresh_button = button("刷新", self.refresh)
        header.pack_end(self.refresh_button)
        self.summary = Gtk.Label(xalign=0)
        outer.pack_start(self.summary, False, False, 0)

        self.profiles, self.profile_view, profiles_page = table(["配置", "类型", "状态", None])
        self.sessions, _, sessions_page = table(["会话", "项目", "正文"])
        tabs = Gtk.Notebook()
        tabs.append_page(profiles_page, Gtk.Label(label="账号与 API"))
        tabs.append_page(sessions_page, Gtk.Label(label="Code 会话"))
        outer.pack_start(tabs, True, True, 0)
        self.controls = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        outer.pack_start(self.controls, False, False, 0)
        profile_bar = Gtk.Box(spacing=6)
        self.controls.pack_start(profile_bar, False, False, 0)
        self.switch = button("切换到所选配置", self.switch_selected)
        self.save = button("保存当前账号", self.save_account)
        self.new_login = button("登录新账号", self.prepare_login)
        self.add_api = button("添加 API", self.add_gateway)
        for widget in [self.switch, self.add_api, self.new_login, self.save]:
            profile_bar.pack_start(widget, False, False, 0)
        self.profile_view.get_selection().connect("changed", lambda _: self.update_buttons())
        self.profile_view.connect("row-activated", lambda *_: self.switch_selected())

        tasks = Gtk.Box(spacing=6)
        self.controls.pack_start(tasks, False, False, 0)
        self.sync = button("同步并重载", lambda: self.perform("--sync"))
        self.recover = button("恢复未完成操作", self.recover_pending)
        self.auto = Gtk.CheckButton(label="每 30 秒归档")
        self.preferences = Gio.Settings.new("com.syncclaude.desktop")
        self.preferences.bind("auto-archive", self.auto, "active", Gio.SettingsBindFlags.DEFAULT)
        for widget in [self.sync, button("立即归档", lambda: self.perform("--archive")), self.auto, self.recover,
                       Gtk.LinkButton.new_with_label("https://claude.ai/settings/usage", "官方用量")]:
            tasks.pack_start(widget, False, False, 0)
        self.feedback = Gtk.Label(xalign=0, selectable=True, wrap=True)
        outer.pack_start(self.feedback, False, False, 0)
        self.timer = GLib.timeout_add_seconds(30, self.tick)
        self.update_buttons()
        self.refresh()

    def on_destroy(self, *_):
        self.closed = True
        GLib.source_remove(self.timer)

    def update_buttons(self):
        ready = self.status.get("compatible") and not self.status.get("pendingRecovery")
        model, item = self.profile_view.get_selection().get_selected()
        self.switch.set_sensitive(bool(ready and item and model[item][2] != "使用中"))
        self.sync.set_sensitive(bool(ready))
        self.save.set_sensitive(bool(ready and self.status.get("canSaveOfficialAccount")))
        self.new_login.set_sensitive(bool(ready))
        self.add_api.set_sensitive(bool(ready))
        self.recover.set_label("继续永久清理" if self.status.get("pendingPurge") else "恢复未完成操作")
        self.recover.set_sensitive(not self.status or bool(self.status.get("pendingRecovery")))

    def recover_pending(self):
        if not self.status.get("pendingPurge"):
            self.perform("--recover")
            return
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.OK_CANCEL, text="继续上次确认的永久清理？")
        dialog.format_secondary_text("将按已保存的清单删除剩余文件。")
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            self.perform("--resume-purge")

    def refresh(self):
        self.perform()

    def perform(self, *args, payload=None):
        if self.busy:
            return
        self.busy = True
        self.controls.set_sensitive(False)
        self.refresh_button.set_sensitive(False)
        self.feedback.set_text("正在处理…")

        def work():
            status, message = None, ""
            try:
                if args:
                    result = subprocess.run([CORE, *args], input=payload or "", text=True,
                                            capture_output=True, check=True)
                    message = result.stdout.strip()
                result = subprocess.run([CORE, "--status"], stdin=subprocess.DEVNULL,
                                        text=True, capture_output=True, check=True)
                status = json.loads(result.stdout)
            except subprocess.CalledProcessError as error:
                message = (message + "\n" + (error.stderr.strip() or "操作失败，请刷新状态。")).strip()
            except (OSError, ValueError) as error:
                message = str(error)
            GLib.idle_add(self.finished, status, message)

        threading.Thread(target=work, daemon=True).start()

    def finished(self, status, message):
        if self.closed:
            return False
        self.busy = False
        self.controls.set_sensitive(True)
        self.refresh_button.set_sensitive(True)
        if status is not None:
            self.status = status
            selection = self.profile_view.get_selection()
            model, item = selection.get_selected()
            selected_id = model[item][3] if item else None
            self.profiles.clear()
            self.sessions.clear()
            active = status["mode"] == "1p"
            self.profiles.append(["官方登录", "官方", "使用中" if active else "", "official"])
            for profile in status["profiles"]:
                self.profiles.append([profile["name"], "API" if profile["kind"] == "gateway" else "官方账号",
                                      "使用中" if profile["active"] else "", profile["id"]])
            for row in self.profiles:
                if row[3] == selected_id:
                    selection.select_iter(row.iter)
                    break
            for session in status["sessions"]:
                self.sessions.append([session["title"], session["project"],
                                      "可用" if session["transcriptAvailable"] else "缺失"])
            if status["compatible"]:
                state = "运行中" if status["running"] else "已退出"
                self.summary.set_text(f"Claude Desktop {status['version']} · {state} · "
                                      f"{status['ownerCount']} 个工作区 · {len(status['sessions'])} 条会话")
            else:
                self.summary.set_text("请安装官方 Claude Desktop 的 Ubuntu 软件包并打开一次。")
        self.feedback.set_text(message)
        self.update_buttons()
        return False

    def tick(self):
        if any(w.get_transient_for() == self and w.get_visible() for w in Gtk.Window.list_toplevels()):
            return True
        if self.auto.get_active() and not self.busy and self.status.get("compatible") and not self.status.get("pendingRecovery"):
            self.perform("--archive")
        return True

    def switch_selected(self):
        model, row = self.profile_view.get_selection().get_selected()
        if row and self.switch.get_sensitive():
            self.perform("--switch", model[row][3])

    def prepare_login(self):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.OK_CANCEL, text="登录另一个官方账号？")
        dialog.format_secondary_text("将保存当前官方登录并重开 Claude。完成新账号登录后，请进入一次 Code，再返回保存账号。")
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            self.perform("--new-login")

    def form(self, title, fields):
        dialog = Gtk.Dialog(title=title, transient_for=self, modal=True)
        dialog.add_buttons("取消", Gtk.ResponseType.CANCEL, "保存", Gtk.ResponseType.OK)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8, margin=14)
        dialog.get_content_area().add(grid)
        entries = {}
        for row, (key, label) in enumerate(fields):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, row, 1, 1)
            if key == "auth":
                widget = Gtk.ComboBoxText()
                for option in ("bearer", "x-api-key"):
                    widget.append_text(option)
                widget.set_active(0)
            else:
                widget = Gtk.Entry(width_chars=35, visibility=key != "key")
            grid.attach(widget, 1, row, 1, 1)
            entries[key] = widget
        dialog.show_all()
        result = None
        if dialog.run() == Gtk.ResponseType.OK:
            result = {key: widget.get_active_text() if key == "auth" else widget.get_text()
                      for key, widget in entries.items()}
        dialog.destroy()
        return result

    def save_account(self):
        values = self.form("保存当前账号", [("name", "账号名称")])
        if values:
            self.perform("--save-account", values["name"])

    def add_gateway(self):
        values = self.form("添加 API 配置", [("name", "配置名称"), ("endpoint", "API 地址"),
                                          ("key", "API Key"), ("auth", "认证方式"),
                                          ("models", "模型（可选，逗号分隔）")])
        if values:
            values["models"] = [value.strip() for value in values["models"].split(",") if value.strip()]
            self.perform("--add-gateway", payload=json.dumps(values))


class App(Gtk.Application):
    def do_activate(self):
        window = self.get_active_window() or Window(self)
        window.show_all()
        window.present()


if __name__ == "__main__":
    app = App(application_id="com.syncclaude.desktop")
    raise SystemExit(app.run(None))
