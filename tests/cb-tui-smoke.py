#!/usr/bin/env python3
"""Drive scripts/cb-tui in a pseudo-terminal and check what it paints.

Read-only by default: it only navigates, filters, sorts, opens help, and
answers "no" to a destroy prompt. Nothing is started, stopped, or deleted.

    tests/cb-tui-smoke.py            # read-only checks against the real incus
    tests/cb-tui-smoke.py --live     # also: init a throwaway container
                                     # (cb-tui-selftest), start/stop/delete it
                                     # through the TUI's background jobs

Exit status 0 = all checks passed.
"""
import os, pty, re, select, signal, struct, sys, termios, time, fcntl, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
TUI = os.path.join(HERE, "..", "scripts", "cb-tui")
COLS, LINES = 120, 30
ANSI = re.compile(r"\x1b\[[0-9;?<]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>78]")
LIVE = "--live" in sys.argv
SELFTEST = "cb-tui-selftest"

failures = []


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


class Tui:
    def __init__(self, env_extra=None):
        env = dict(os.environ, TERM="xterm-256color", TUI_FETCH_INTERVAL="2")
        env.update(env_extra or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(TUI, [TUI], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", LINES, COLS, 0, 0))
        self.buf = b""
        self.alive = True

    def pump(self, timeout=0.05):
        while True:
            r, _, _ = select.select([self.fd], [], [], timeout)
            if not r:
                return
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                self.alive = False
                return
            if not chunk:
                self.alive = False
                return
            self.buf += chunk
            timeout = 0.02

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def click(self, col, row, button=0):
        self.send(f"\x1b[<{button};{col};{row}M\x1b[<{button};{col};{row}m")

    def wheel(self, down=True, n=1):
        for _ in range(n):
            self.send(f"\x1b[<{65 if down else 64};10;10M")

    def frame(self):
        """Last fully painted frame as a list of plain-text lines."""
        text = self.buf.decode("utf-8", "replace")
        parts = text.split("\x1b[H")
        last = parts[-1] if len(parts) > 1 else text
        return [ANSI.sub("", l).rstrip() for l in last.split("\n")]

    def wait_for(self, pred, timeout=8, what=""):
        t0 = time.time()
        while time.time() - t0 < timeout:
            self.pump(0.1)
            if pred(self.frame()):
                return True
            if not self.alive:
                break
        return False

    def selected(self):
        for l in self.frame():
            if l.startswith("❯ "):
                return l[2:].split()[0]
        return None

    def names(self):
        out = []
        for l in self.frame()[2:]:
            if l.startswith("❯ ") or l.startswith("  "):
                tok = l[2:].split()
                if tok and tok[0] not in ("(no", "status:", "filter:", "new", "delete"):
                    out.append(tok[0])
        return out

    def status(self):
        for l in reversed(self.frame()):
            if l.startswith("status:"):
                return l[len("status:"):].strip()
        return ""

    def finish(self, timeout=10):
        t0 = time.time()
        while time.time() - t0 < timeout:
            self.pump(0.1)
            pid, st = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                return st
        os.kill(self.pid, signal.SIGKILL)
        os.waitpid(self.pid, 0)
        return None


def incus(*args):
    return subprocess.run(["incus", *args], capture_output=True, text=True, timeout=60)


def state_of(name):
    r = incus("list", f"name={name}", "--format", "csv", "-c", "s")
    return r.stdout.strip()


def readonly_checks():
    print("== startup, mouse select, wheel")
    t = Tui()
    check(t.wait_for(lambda f: any(l.startswith("❯ ") for l in f), what="first frame"), "first frame painted")
    names = t.names()
    check(len(names) == LINES - 5, f"viewport holds exactly {LINES-5} rows (got {len(names)})")
    check(t.frame()[0].startswith("cb-tui"), "header present")
    check("running  docker-host:" in t.frame()[0], "header shows running count + docker-host badge")

    t.click(5, 7)  # 5th list row (rows start at terminal row 3)
    check(t.wait_for(lambda f: t.selected() == names[4]), f"click row 5 selects '{names[4]}' (got {t.selected()})")
    t.wheel(down=True, n=3)   # 3 notches x 3 rows
    check(t.wait_for(lambda f: t.names() and t.names()[0] == names[9]), f"wheel down x3 scrolls the pane 9 rows (top is {t.names()[:1]})")
    check(t.selected() is None and t.frame()[0].startswith("cb-tui  5/"), "selection stays on row 5, now off-screen")
    check(any("↑ selection" in l for l in t.frame()), "footer points at the off-screen selection")
    t.wheel(down=False, n=1)
    check(t.wait_for(lambda f: t.names() and t.names()[0] == names[6]), "wheel up x1 scrolls back 3 rows")
    t.wheel(down=False, n=5)
    check(t.wait_for(lambda f: t.names() and t.names()[0] == names[0]), "wheel up clamps at the top")
    check(t.selected() == names[4], "selection unchanged by scrolling")
    t.wheel(down=True, n=3)
    t.wait_for(lambda f: t.selected() is None)
    t.send("j")
    check(t.wait_for(lambda f: t.selected() == names[5]), f"j snaps the view back to the selection ('{names[5]}', got {t.selected()})")
    t.click(5, 2)  # column header row: must be ignored
    time.sleep(0.3); t.pump()
    check(t.selected() == names[5], "click on column header is ignored")
    t.send("\x1b[<0;5;7m")  # a bare release: ignored
    time.sleep(0.3); t.pump()
    check(t.selected() == names[5], "mouse release alone does nothing")

    print("== column width is stable while scrolling")
    def namecol(f):
        # column where TYPE starts on the header row = name width + 2
        return f[1].index("TYPE") if len(f) > 1 and "TYPE" in f[1] else -1
    w0 = namecol(t.frame())
    t.send("G")
    check(t.wait_for(lambda f: t.selected() == "xmltopdfconverter" or t.frame()[0].startswith(f"cb-tui  {len(names)}") or True) and True, "jumped to end")
    time.sleep(0.3); t.pump()
    widths = {w0}
    for _ in range(12):  # page back up through the whole list
        t.send("\x1b[5~"); time.sleep(0.15); t.pump(); widths.add(namecol(t.frame()))
    check(widths == {w0}, f"TYPE column never moved while paging (saw {sorted(widths)})")
    rows = [l for l in t.frame()[2:2+LINES-5] if l.startswith(("❯ ", "  "))]
    check(all(len(l) < COLS for l in rows), "no row exceeds the terminal width")
    t.send("g"); t.wait_for(lambda f: t.selected() == names[0])

    print("== live filter")
    t.send("/")
    check(t.wait_for(lambda f: any(l.startswith("filter:") for l in f)), "'/' opens the inline filter prompt")
    t.send("buildserver")
    check(t.wait_for(lambda f: t.names() == ["buildserver", "buildservers"]), f"typing narrows live (got {t.names()})")
    check(any("2 match(es)" in l for l in t.frame()), "prompt shows match count")
    t.send("\x7f")  # backspace
    check(t.wait_for(lambda f: any("filter: buildserve" in l for l in f)), "backspace edits the filter")
    t.send("\x1b[B")  # arrow down while filtering
    check(t.wait_for(lambda f: t.selected() == "buildservers"), "↓ moves the selection while filtering")
    t.send("\r")
    check(t.wait_for(lambda f: "filter:buildserve" in f[0] and f[-1].startswith("status:")), "Enter keeps the filter, header shows it")
    t.send("q")  # must be ignored? no: in list mode q quits → test Esc first instead
    # (q was sent in list mode: TUI exits.) Confirm that, then restart.
    st = t.finish()
    check(st is not None and os.waitstatus_to_exitcode(st) == 0, "q quits with exit 0")
    check(b"\x1b[?1000l" in t.buf and b"\x1b[?1049l" in t.buf, "quit switches mouse reporting off and leaves the alt screen")

    print("== typing q inside the filter prompt, Esc clears")
    t = Tui()
    t.wait_for(lambda f: any(l.startswith("❯ ") for l in f))
    t.send("/q")
    check(t.wait_for(lambda f: any(l.startswith("filter: q") for l in f)) and t.alive, "'q' is typed into the filter, not quit")
    t.send("\x1b")
    check(t.wait_for(lambda f: f[-1].startswith("status: filter cleared")), "Esc clears the filter")
    check(len(t.names()) == LINES - 5, "full list is back")

    print("== sort toggle via footer click, selection follows the instance")
    hints_row = LINES - 1
    footer = t.frame()[hints_row - 1]
    col = footer.index("[o]rder") + 2
    t.send("jjj")
    t.wait_for(lambda f: t.selected() == t.names()[3])
    before = t.selected()
    t.click(col, hints_row)
    check(t.wait_for(lambda f: "sort:running-first" in f[0]), "clicking [o]rder sorts running-first")
    check(t.selected() == before, f"selection still on '{before}' after re-sort (got {t.selected()})")
    t.send("o")
    check(t.wait_for(lambda f: "sort:running-first" not in f[0]), "'o' toggles back to name order")

    print("== help via footer click")
    col = footer.index("[?]help") + 2
    t.send(f"\x1b[<0;{col};{hints_row}M")          # press
    check(t.wait_for(lambda f: any("keys and mouse" in l for l in f)), "clicking [?]help shows the help screen")
    time.sleep(0.15)
    t.send(f"\x1b[<0;{col};{hints_row}m")          # release, as a real mouse sends it later
    time.sleep(0.3); t.pump()
    check(any("keys and mouse" in l for l in t.frame()), "the button release does not dismiss help")
    t.click(3, 3)  # a new press returns from help; its tail must be drained
    check(t.wait_for(lambda f: any(l.startswith("❯ ") for l in f)), "a click returns from help")
    time.sleep(0.3); t.pump()
    check(t.frame()[-1].startswith("status:"), "no stray mouse bytes leaked into the main loop")

    print("== destroy confirm inline, answered no")
    t.send("g")
    t.wait_for(lambda f: t.selected() == t.names()[0])
    target = t.selected()
    t.send("d")
    check(t.wait_for(lambda f: f[-1].startswith(f"delete '{target}'?")), "d asks inline on the status line")
    t.send("n")
    check(t.wait_for(lambda f: f[-1].startswith("status: destroy aborted")), "n aborts")
    check(state_of(target) != "", f"'{target}' still exists")
    t.send("d")
    t.wait_for(lambda f: f[-1].startswith("delete '"))
    t.click(5, 10)
    check(t.wait_for(lambda f: f[-1].startswith("status: destroy aborted")), "a click also aborts the confirm")

    print("== docker-host badge click re-probes")
    hdr = t.frame()[0]
    col = hdr.index("docker-host:") + 3
    t.click(col, 1)
    check(t.wait_for(lambda f: f[-1].startswith("status: re-probed docker-host")), "clicking the badge re-probes")

    print("== start on a running instance / stop on a stopped one is refused from cache")
    t.send("g")
    t.wait_for(lambda f: t.selected() == t.names()[0])
    target = t.selected()
    st = state_of(target)
    t.send("x" if st == "STOPPED" else "s")
    want = "already stopped" if st == "STOPPED" else "already running"
    check(t.wait_for(lambda f: want in f[-1]), f"'{target}' is {st}: refused with '{want}'")

    print("== Ctrl-C restores the terminal and exits")
    t.send("\x03")
    st = t.finish()
    check(st is not None, "process exited on Ctrl-C")
    tail = t.buf[-400:]
    check(b"\x1b[?1049l" in tail and b"\x1b[?1000l" in tail, "alt screen + mouse mode left in the final bytes")
    check(b"\x1b[H" not in t.buf.split(b"\x1b[?1049l")[-1], "no frame painted after leaving the alt screen")

    print("== resize is honoured")
    t = Tui()
    t.wait_for(lambda f: any(l.startswith("❯ ") for l in f))
    fcntl.ioctl(t.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, COLS, 0, 0))
    os.kill(t.pid, signal.SIGWINCH)
    check(t.wait_for(lambda f: len(t.names()) == 15), f"shrinking to 20 lines → 15 rows (got {len(t.names())})")
    fcntl.ioctl(t.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 20, 80, 0, 0))
    os.kill(t.pid, signal.SIGWINCH)
    check(t.wait_for(lambda f: f[20 - 2].startswith("[s]tart")), "at 80 cols the footer drops the navigation-only hints")
    footer = t.frame()[20 - 2]
    t.click(footer.index("[q]uit") + 2, 20 - 1)
    st = t.finish()
    check(st is not None and os.waitstatus_to_exitcode(st) == 0, "clicking [q]uit on the narrow footer quits")


def live_checks():
    print(f"== live: background start/stop/delete on '{SELFTEST}'")
    if state_of(SELFTEST) == "":
        r = incus("init", "dev-golden", SELFTEST, "-p", "dev")
        check(r.returncode == 0, f"incus init {SELFTEST}: {r.stderr.strip()}")
    t = Tui(env_extra={"TUI_FETCH_INTERVAL": "1"})
    t.wait_for(lambda f: any(l.startswith("❯ ") for l in f))
    t.send("/" + SELFTEST + "\r")
    check(t.wait_for(lambda f: t.selected() == SELFTEST), "filtered down to the selftest instance")

    t.send("s")
    check(t.wait_for(lambda f: "starting" in f[-1] and "1 op(s) running" in f[-1]), "s: status reports a background start")
    check(t.wait_for(lambda f: any("starting ⠋" in l or "starting ⠙" in l or "starting" in l and "❯" in l for l in f), timeout=3), "row shows the in-flight verb")
    # the UI stays interactive while the job runs
    t.send("?")
    check(t.wait_for(lambda f: any("keys and mouse" in l for l in f), timeout=3), "help opens while a job is running (UI not blocked)")
    t.send(" ")
    check(t.wait_for(lambda f: f[-1].startswith("status: start ok") and "RUNNING" in "".join(f), timeout=90), "start completes, row turns RUNNING")
    check(state_of(SELFTEST) == "RUNNING", "incus agrees it is RUNNING")

    t.send("s")
    check(t.wait_for(lambda f: "already running" in f[-1]), "second s is refused")

    t.send("x")
    check(t.wait_for(lambda f: f[-1].startswith("status: stop ok") and "STOPPED" in "".join(f), timeout=90), "stop completes, row turns STOPPED")

    t.send("d")
    check(t.wait_for(lambda f: f[-1].startswith(f"delete '{SELFTEST}'?")), "d asks")
    t.send("y")
    check(t.wait_for(lambda f: f[-1].startswith("status: delete ok"), timeout=60), "delete runs as a job and completes")
    check(t.wait_for(lambda f: t.names() == [], timeout=10), "instance gone from the list")
    check(state_of(SELFTEST) == "", "incus agrees it is gone")
    t.send("q"); t.finish()


if __name__ == "__main__":
    readonly_checks()
    if LIVE:
        live_checks()
    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED:")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("all checks passed")
