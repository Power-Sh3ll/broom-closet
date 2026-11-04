#!/usr/bin/env python3
"""Broom Closet — a tiny private chat room served over plain TCP.

Speaks newline-delimited UTF-8 in both directions, so a guest with nothing
but `nc closet.example 7777` can still join. Bind it to a Tailscale address
and the tailnet is the access list.

    ./server.py --host 100.x.y.z

Run `./server.py --help` for the rest.
"""

from __future__ import annotations

import argparse
import asyncio
import collections
import contextlib
import hashlib
import hmac
import logging
import os
import secrets
import signal
import time
from datetime import datetime

MAX_LINE = 2048          # bytes; longer lines are dropped, not buffered forever
MAX_DISCARD = 1 << 20    # give up on a sender who never sends a newline
MAX_MSG_CHARS = 800
NICK_MAX = 20
SCROLLBACK = 80          # lines replayed to each arrival
BURST = 10               # messages allowed in a burst
REFILL_PER_SEC = 2.0     # token refill rate, i.e. sustained messages/second
AUTH_TRIES = 3           # wrong passphrases allowed per connection
AUTH_TIMEOUT = 60        # seconds to answer the challenge before being dropped

log = logging.getLogger("closet")


def stamp() -> str:
    return datetime.now().strftime("%H:%M")


def load_secret(path: str | None) -> bytes | None:
    """Shared secret from a file or $CLOSET_SECRET. None means no auth.

    Deliberately not a command-line argument: anything passed as an argv
    entry is visible to every user on the box via `ps`.
    """
    if path:
        with open(path, "rb") as fh:
            return fh.read().strip() or None
    env = os.environ.get("CLOSET_SECRET", "").strip()
    return env.encode() if env else None


def clean_nick(raw: str) -> str | None:
    """Trim a requested nick to something safe, or None if nothing is left."""
    nick = "".join(c for c in raw.strip() if c.isalnum() or c in "_-[]{}^|").strip()
    return nick[:NICK_MAX] or None


class Member:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        self.reader = reader
        self.writer = writer
        self.nick: str | None = None
        self.joined = time.monotonic()
        self.tokens = float(BURST)
        self.last_refill = time.monotonic()
        peer = writer.get_extra_info("peername") or ("?", 0)
        self.peer = f"{peer[0]}:{peer[1]}"

    @property
    def name(self) -> str:
        return self.nick or self.peer

    def send(self, line: str) -> None:
        """Queue a line. Never raises — a dead socket is reaped by its reader."""
        if self.writer.is_closing():
            return
        with contextlib.suppress(Exception):
            self.writer.write(line.encode("utf-8", "replace") + b"\r\n")

    def allow(self) -> bool:
        """Token bucket, so one person cannot flood the room."""
        now = time.monotonic()
        self.tokens = min(BURST, self.tokens + (now - self.last_refill) * REFILL_PER_SEC)
        self.last_refill = now
        if self.tokens < 1.0:
            return False
        self.tokens -= 1.0
        return True


class Room:
    def __init__(self, motd: str | None = None, secret: bytes | None = None):
        self.members: set[Member] = set()
        self.history: collections.deque[str] = collections.deque(maxlen=SCROLLBACK)
        self.motd = motd
        self.secret = secret

    # --- delivery ------------------------------------------------------

    def post(self, line: str, *, keep: bool = True) -> None:
        """Send to everyone who has picked a nick, and remember it."""
        if keep:
            self.history.append(line)
        for m in self.members:
            if m.nick:
                m.send(line)

    def say(self, speaker: Member, text: str) -> None:
        self.post(f"[{stamp()}] <{speaker.nick}> {text}")

    def notice(self, text: str) -> None:
        self.post(f"[{stamp()}] * {text}")

    def named(self) -> list[str]:
        return sorted((m.nick for m in self.members if m.nick), key=str.lower)

    def find(self, nick: str) -> Member | None:
        low = nick.lower()
        return next((m for m in self.members if m.nick and m.nick.lower() == low), None)

    # --- join / part ---------------------------------------------------

    async def authenticate(self, m: Member) -> bool:
        """Prove knowledge of the shared secret before seeing anything.

        The challenge is a fresh nonce and the expected answer is
        HMAC-SHA256(secret, nonce), so the secret never crosses the wire and
        a recorded answer cannot be replayed. A client that cannot compute
        that may instead send the passphrase itself, which is convenient for
        a bare `nc` guest but readable by anyone sniffing an unencrypted link.
        """
        for attempt in range(AUTH_TRIES):
            nonce = secrets.token_hex(16)
            expected = hmac.new(self.secret, nonce.encode(), hashlib.sha256).hexdigest()
            m.send(f"AUTH {nonce}")
            try:
                reply = await asyncio.wait_for(self.read_line(m), AUTH_TIMEOUT)
            except asyncio.TimeoutError:
                log.warning("auth timeout from %s", m.peer)
                m.send("! auth timed out")
                return False
            if reply is None:
                return False

            reply = reply.strip()
            if reply.startswith("hmac:"):
                ok = hmac.compare_digest(reply[5:].strip().lower(), expected)
            else:
                ok = hmac.compare_digest(reply.encode("utf-8", "replace"), self.secret)
            if ok:
                m.send("+ auth ok")
                return True

            log.warning("auth failure from %s (%d/%d)", m.peer, attempt + 1, AUTH_TRIES)
            m.send("! wrong passphrase")
            await asyncio.sleep(1.0 + attempt)      # slow down guessing

        m.send("! too many attempts")
        return False

    async def welcome(self, m: Member) -> bool:
        """Negotiate a nick. False means they hung up or gave up."""
        m.send("== broom closet ==")
        for _ in range(5):
            m.send("pick a nick: ")
            raw = await self.read_line(m)
            if raw is None:
                return False
            nick = clean_nick(raw)
            if not nick:
                m.send("! letters, digits, and _-[]{}^| only")
                continue
            if self.find(nick):
                m.send(f"! {nick} is taken")
                continue
            m.nick = nick
            break
        else:
            m.send("! giving up, bye")
            return False

        if self.motd:
            m.send(f"[{stamp()}] * {self.motd}")
        if self.history:
            m.send(f"-- last {len(self.history)} lines --")
            for line in self.history:
                m.send(line)
            m.send("-- end of scrollback --")
        others = [n for n in self.named() if n != m.nick]
        m.send(f"[{stamp()}] * here now: {', '.join(others) or 'just you'}")
        m.send(f"[{stamp()}] * /help for commands")
        self.notice(f"{m.nick} joined")
        log.info("join %s (%s) — %d online", m.nick, m.peer, len(self.named()))
        return True

    def part(self, m: Member, why: str) -> None:
        self.members.discard(m)
        if m.nick:
            self.notice(f"{m.nick} left ({why})")
            log.info("part %s (%s) — %d online", m.nick, why, len(self.named()))

    # --- input ---------------------------------------------------------

    async def discard_line(self, m: Member) -> bool:
        """Drop an over-long line, newline included.

        False means the sender hung up or is streaming junk with no newline in
        sight, which is a disconnect rather than something to forgive.
        """
        dropped = 0
        while dropped < MAX_DISCARD:
            try:
                chunk = await m.reader.read(MAX_LINE)
            except (ConnectionError, asyncio.CancelledError):
                return False
            if not chunk:
                return False
            dropped += len(chunk)
            if b"\n" in chunk:
                return True
        log.warning("dropping %s: %d bytes with no newline", m.name, dropped)
        return False

    async def read_line(self, m: Member) -> str | None:
        """One line of input, or None at EOF. Overlong lines come back empty."""
        try:
            raw = await m.reader.readuntil(b"\n")
        except asyncio.IncompleteReadError as e:
            if not e.partial:
                return None
            raw = e.partial
        except asyncio.LimitOverrunError:
            # Too long to buffer. The bytes are still queued, so they must be
            # drained here or the next readuntil raises on them forever.
            if not await self.discard_line(m):
                return None
            m.send("! line too long, dropped")
            return ""
        except (ConnectionError, asyncio.CancelledError):
            return None
        return raw.decode("utf-8", "replace").rstrip("\r\n")

    async def serve(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        m = Member(reader, writer)
        self.members.add(m)
        why = "disconnected"
        try:
            if self.secret and not await self.authenticate(m):
                why = "auth failed"
                return
            if not await self.welcome(m):
                return
            while True:
                line = await self.read_line(m)
                if line is None:
                    break
                line = line.strip()
                if not line:
                    continue
                if not m.allow():
                    m.send("! slow down")
                    continue
                if line.startswith("/"):
                    if self.command(m, line):
                        why = "quit"
                        break
                else:
                    self.say(m, line[:MAX_MSG_CHARS])
        except (ConnectionError, asyncio.CancelledError):
            pass
        except Exception:
            log.exception("session %s died", m.name)
            why = "error"
        finally:
            self.part(m, why)
            with contextlib.suppress(Exception):
                await writer.drain()
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()

    # --- commands ------------------------------------------------------

    def command(self, m: Member, line: str) -> bool:
        """Handle a /command. Returns True if the member asked to leave."""
        verb, _, rest = line[1:].partition(" ")
        verb = verb.lower()
        rest = rest.strip()[:MAX_MSG_CHARS]

        if verb in ("quit", "part", "exit"):
            m.send("bye")
            return True

        if verb == "help":
            m.send("commands: /nick <name>  /me <action>  /msg <nick> <text>  "
                   "/who  /uptime  /quit")
        elif verb == "nick":
            new = clean_nick(rest)
            if not new:
                m.send("! usage: /nick <name>")
            elif self.find(new):
                m.send(f"! {new} is taken")
            else:
                old, m.nick = m.nick, new
                self.notice(f"{old} is now {new}")
        elif verb == "me":
            if rest:
                self.notice(f"{m.nick} {rest}")
            else:
                m.send("! usage: /me <action>")
        elif verb == "msg":
            target, _, text = rest.partition(" ")
            peer = self.find(target) if target else None
            text = text.strip()
            if not peer:
                m.send(f"! no one here called {target or '<nick>'}")
            elif not text:
                m.send("! usage: /msg <nick> <text>")
            else:
                peer.send(f"[{stamp()}] *{m.nick}* {text}")
                m.send(f"[{stamp()}] -> *{target}* {text}")
        elif verb == "who":
            names = self.named()
            m.send(f"[{stamp()}] * {len(names)} here: {', '.join(names)}")
        elif verb == "uptime":
            mins = int((time.monotonic() - m.joined) // 60)
            m.send(f"[{stamp()}] * you have been here {mins} min")
        else:
            m.send(f"! unknown command /{verb} — try /help")
        return False


async def main() -> None:
    ap = argparse.ArgumentParser(description="Broom Closet chat server")
    ap.add_argument("--host", default="127.0.0.1",
                    help="address to bind; use your Tailscale IP to stay private "
                         "(default: %(default)s)")
    ap.add_argument("--port", type=int, default=7777, help="default: %(default)s")
    ap.add_argument("--motd", help="greeting shown to everyone who joins")
    ap.add_argument("--secret-file", metavar="PATH",
                    help="file holding the shared passphrase; without this (and "
                         "without $CLOSET_SECRET) the room is open to anyone who "
                         "can reach the port")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s",
                        datefmt="%H:%M:%S")

    try:
        secret = load_secret(args.secret_file)
    except OSError as e:
        ap.error(f"cannot read secret file: {e}")

    room = Room(motd=args.motd, secret=secret)
    log.info("auth %s", "required" if secret else "DISABLED — anyone can join")
    server = await asyncio.start_server(room.serve, args.host, args.port, limit=MAX_LINE)
    where = ", ".join(str(s.getsockname()[:2]) for s in server.sockets)
    log.info("listening on %s", where)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(sig, stop.set)

    async with server:
        await stop.wait()

    log.info("closing up")
    room.post(f"[{stamp()}] * server shutting down", keep=False)
    for m in list(room.members):
        with contextlib.suppress(Exception):
            m.writer.close()


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main())
