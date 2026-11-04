#!/usr/bin/env python3
"""Broom Closet client — a fixed input line at the bottom, chat scrolling above.

    ./client.py                        # 127.0.0.1:7777
    ./client.py closet.ts.net --nick jay

Nothing here is required to join: the server speaks plain lines, so
`nc <host> 7777` works too. This just makes it pleasant.
"""

from __future__ import annotations

import argparse
import asyncio
import codecs
import contextlib
import getpass
import hashlib
import hmac
import os
import shutil
import signal
import sys

NICK_COLORS = (36, 32, 33, 35, 34, 96, 92, 93, 95, 94)
PROMPT = "> "
MAX_SEND = 800        # stay well under the server's line limit
AUTH_TRIES = 3        # mirrors the server, to bound the handshake loop


class Palette:
    """ANSI escapes, or no-ops when stdout is not a terminal."""

    def __init__(self, enabled: bool):
        self.on = enabled

    def paint(self, text: str, code: int) -> str:
        return f"\033[{code}m{text}\033[0m" if self.on else text

    def dim(self, text: str) -> str:
        return self.paint(text, 90)

    def for_nick(self, nick: str) -> str:
        code = NICK_COLORS[sum(nick.encode()) % len(NICK_COLORS)]
        return self.paint(nick, code)

    def line(self, raw: str) -> str:
        """Colorize one server line based on its shape."""
        if raw.startswith("!"):
            return self.paint(raw, 31)
        if raw.startswith("--") or raw.startswith("=="):
            return self.dim(raw)

        head, sep, rest = raw.partition(" ")
        if not (sep and head.startswith("[") and head.endswith("]")):
            return raw
        ts = self.dim(head)

        if rest.startswith("* "):
            return f"{ts} {self.paint(rest, 90)}"
        if rest.startswith("<"):
            nick, close, text = rest[1:].partition("> ")
            if close:
                return f"{ts} {self.dim('<')}{self.for_nick(nick)}{self.dim('>')} {text}"
        if rest.startswith("*") or rest.startswith("-> *"):
            return f"{ts} {self.paint(rest, 35)}"
        return f"{ts} {rest}"


class Editor:
    """A one-line editor that repaints itself below whatever has scrolled past."""

    def __init__(self, palette: Palette, tty: bool):
        self.palette = palette
        self.tty = tty
        self.buf = ""
        self.pos = 0
        self.history: list[str] = []
        self.hist_idx = 0
        self.stash = ""

    # --- painting ------------------------------------------------------

    def width(self) -> int:
        return max(20, shutil.get_terminal_size((80, 24)).columns)

    def draw(self) -> None:
        """Redraw the input line in place and park the cursor correctly."""
        if not self.tty:
            return
        avail = self.width() - len(PROMPT) - 1
        start = 0
        if self.pos > avail:                     # scroll the window with the cursor
            start = self.pos - avail
        visible = self.buf[start:start + avail]
        sys.stdout.write("\r\033[K" + self.palette.dim(PROMPT) + visible)
        back = len(visible) - (self.pos - start)
        if back > 0:
            sys.stdout.write(f"\033[{back}D")
        sys.stdout.flush()

    def emit(self, text: str) -> None:
        """Print an incoming line above the input line, then restore it."""
        sys.stdout.write(("\r\033[K" if self.tty else "") + text + "\n")
        sys.stdout.flush()
        self.draw()

    # --- editing -------------------------------------------------------

    def insert(self, text: str) -> None:
        self.buf = self.buf[:self.pos] + text + self.buf[self.pos:]
        self.pos += len(text)

    def backspace(self) -> None:
        if self.pos:
            self.buf = self.buf[:self.pos - 1] + self.buf[self.pos:]
            self.pos -= 1

    def delete_word(self) -> None:
        left = self.buf[:self.pos].rstrip()
        cut = left.rfind(" ") + 1
        self.buf = self.buf[:cut] + self.buf[self.pos:]
        self.pos = cut

    def recall(self, delta: int) -> None:
        if not self.history:
            return
        if self.hist_idx == len(self.history):
            self.stash = self.buf
        self.hist_idx = max(0, min(len(self.history), self.hist_idx + delta))
        self.buf = self.stash if self.hist_idx == len(self.history) else self.history[self.hist_idx]
        self.pos = len(self.buf)

    def keypress(self, seq: str) -> None:
        """Act on a complete escape sequence; ignore ones we do not bind."""
        if seq in ("\033[A", "\033OA"):
            self.recall(-1)
        elif seq in ("\033[B", "\033OB"):
            self.recall(1)
        elif seq in ("\033[C", "\033OC"):
            self.pos = min(len(self.buf), self.pos + 1)
        elif seq in ("\033[D", "\033OD"):
            self.pos = max(0, self.pos - 1)
        elif seq in ("\033[H", "\033OH", "\033[1~", "\033[7~"):
            self.pos = 0
        elif seq in ("\033[F", "\033OF", "\033[4~", "\033[8~"):
            self.pos = len(self.buf)
        elif seq == "\033[3~":                              # delete
            if self.pos < len(self.buf):
                self.buf = self.buf[:self.pos] + self.buf[self.pos + 1:]

    def take(self) -> str:
        """Pull the finished line and reset for the next one."""
        line, self.buf, self.pos = self.buf, "", 0
        if line.strip() and (not self.history or self.history[-1] != line):
            self.history.append(line)
        self.hist_idx = len(self.history)
        self.stash = ""
        return line


class RawTerminal:
    """Put the tty in raw mode for the duration, and always put it back."""

    def __init__(self, enabled: bool):
        self.enabled = enabled
        self.saved = None

    def __enter__(self):
        if self.enabled:
            import termios, tty
            self.saved = termios.tcgetattr(sys.stdin.fileno())
            tty.setraw(sys.stdin.fileno())
        return self

    def __exit__(self, *exc):
        if self.saved is not None:
            import termios
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self.saved)
            sys.stdout.write("\r\033[K")
            sys.stdout.flush()


def resolve_secret(path: str | None) -> bytes | None:
    """Secret from a file or $CLOSET_SECRET, or None to prompt later."""
    if path:
        with open(path, "rb") as fh:
            return fh.read().strip() or None
    env = os.environ.get("CLOSET_SECRET", "").strip()
    return env.encode() if env else None


async def handshake(reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                    secret_path: str | None, palette: Palette) -> bool:
    """Answer an AUTH challenge if the server opens with one.

    Runs before the terminal goes into raw mode so getpass can prompt
    normally. Returns False if we were turned away.
    """
    try:
        secret = resolve_secret(secret_path)
    except OSError as e:
        print(f"cannot read secret file: {e}", file=sys.stderr)
        return False

    rejected = False
    for _ in range(3 * AUTH_TRIES):          # bounded; server allows AUTH_TRIES
        raw = await reader.readline()
        if not raw:
            print("server closed the connection during auth", file=sys.stderr)
            return False
        line = raw.decode("utf-8", "replace").rstrip("\r\n")

        if line.startswith("AUTH "):
            if secret is None:
                if not sys.stdin.isatty():
                    print("passphrase rejected" if rejected else
                          "server wants a passphrase: set $CLOSET_SECRET or pass "
                          "--secret-file", file=sys.stderr)
                    return False
                secret = getpass.getpass("passphrase: ").strip().encode()
            nonce = line[5:].strip().encode()
            mac = hmac.new(secret, nonce, hashlib.sha256).hexdigest()
            writer.write(f"hmac:{mac}\r\n".encode())
            await writer.drain()
            continue

        if line.startswith("+"):             # accepted
            return True
        if line.startswith("!"):             # rejected; prompt again next round
            print(palette.line(line))
            secret, rejected = None, True
            continue

        print(palette.line(line))            # no auth configured; that was the banner
        return True

    print("auth did not complete", file=sys.stderr)
    return False


async def pump_incoming(reader: asyncio.StreamReader, ed: Editor, palette: Palette) -> None:
    """Server -> screen, until the connection ends."""
    while True:
        raw = await reader.readline()
        if not raw:
            ed.emit(palette.paint("* disconnected", 31))
            return
        ed.emit(palette.line(raw.decode("utf-8", "replace").rstrip("\r\n")))


def wire_keyboard(ed: Editor, outbox: asyncio.Queue, done: asyncio.Event) -> None:
    """Feed raw stdin bytes through the editor; completed lines go to outbox."""
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    pending = ""   # holds a partial escape sequence between reads

    def on_readable() -> None:
        nonlocal pending
        try:
            data = os.read(sys.stdin.fileno(), 1024)
        except (BlockingIOError, InterruptedError):
            return
        if not data:
            done.set()
            return

        keys = pending + decoder.decode(data)
        pending = ""
        i, n = 0, len(keys)
        while i < n:
            ch = keys[i]
            if ch == "\033":                               # CSI / escape sequence
                j = i + 1
                if j < n and keys[j] in "[O":
                    j += 1
                    while j < n and not ("\x40" <= keys[j] <= "\x7e"):
                        j += 1          # params and intermediates
                if j >= n:
                    pending = keys[i:]                     # wait for the rest
                    break
                ed.keypress(keys[i:j + 1])
                i = j + 1
                continue
            if ch in ("\r", "\n"):
                line = ed.take()
                sys.stdout.write("\r\033[K")
                if line.strip():
                    outbox.put_nowait(line)
            elif ch in ("\x7f", "\x08"):
                ed.backspace()
            elif ch == "\x03":                             # ctrl-c
                done.set()
                return
            elif ch == "\x04":                             # ctrl-d on an empty line
                if not ed.buf:
                    done.set()
                    return
            elif ch == "\x15":                             # ctrl-u
                ed.buf, ed.pos = "", 0
            elif ch == "\x17":                             # ctrl-w
                ed.delete_word()
            elif ch == "\x01":
                ed.pos = 0
            elif ch == "\x05":
                ed.pos = len(ed.buf)
            elif ch == "\x0c":                             # ctrl-l
                sys.stdout.write("\033[2J\033[H")
            elif ch.isprintable():
                ed.insert(ch)
            i += 1
        ed.draw()

    asyncio.get_running_loop().add_reader(sys.stdin.fileno(), on_readable)


async def chat(args: argparse.Namespace) -> int:
    try:
        reader, writer = await asyncio.open_connection(args.host, args.port)
    except OSError as e:
        print(f"could not reach {args.host}:{args.port} — {e}", file=sys.stderr)
        return 1

    # Raw mode and add_reader(stdin) are POSIX-only, so Windows falls back to
    # plain line-at-a-time input rather than crashing on `import termios`.
    interactive = sys.stdin.isatty() and os.name == "posix"
    palette = Palette(sys.stdout.isatty() and os.environ.get("TERM") != "dumb")

    if not await handshake(reader, writer, args.secret_file, palette):
        with contextlib.suppress(Exception):
            writer.close()
            await writer.wait_closed()
        return 1

    ed = Editor(palette, tty=interactive and sys.stdout.isatty())
    outbox: asyncio.Queue[str] = asyncio.Queue()
    done = asyncio.Event()

    if args.nick:
        writer.write(args.nick.encode() + b"\r\n")   # answers the server's first prompt

    with RawTerminal(interactive):
        if interactive:
            wire_keyboard(ed, outbox, done)
            ed.draw()

        async def sender() -> None:
            while True:
                line = await outbox.get()
                writer.write(line[:MAX_SEND].encode("utf-8", "replace") + b"\r\n")
                await writer.drain()
                if line.strip().lower() in ("/quit", "/exit", "/part"):
                    done.set()
                    return

        async def dumb_stdin() -> None:
            """Fallback for pipes: read lines without touching the terminal."""
            loop = asyncio.get_running_loop()
            while True:
                line = await loop.run_in_executor(None, sys.stdin.readline)
                if not line:
                    done.set()
                    return
                outbox.put_nowait(line.rstrip("\n"))

        tasks = [asyncio.create_task(pump_incoming(reader, ed, palette)),
                 asyncio.create_task(sender())]
        if not interactive:
            tasks.append(asyncio.create_task(dumb_stdin()))

        with contextlib.suppress(NotImplementedError):
            asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, done.set)

        waiter = asyncio.create_task(done.wait())
        await asyncio.wait([*tasks, waiter], return_when=asyncio.FIRST_COMPLETED)

        for t in (*tasks, waiter):
            t.cancel()
        if interactive:
            with contextlib.suppress(Exception):
                asyncio.get_running_loop().remove_reader(sys.stdin.fileno())

    with contextlib.suppress(Exception):
        writer.close()
        await writer.wait_closed()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Broom Closet chat client")
    ap.add_argument("host", nargs="?", default="127.0.0.1")
    ap.add_argument("port", nargs="?", type=int, default=7777)
    ap.add_argument("--nick", help="claim this nick instead of being asked")
    ap.add_argument("--secret-file", metavar="PATH",
                    help="file holding the shared passphrase; $CLOSET_SECRET also "
                         "works, otherwise you are prompted")
    args = ap.parse_args()
    try:
        return asyncio.run(chat(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
