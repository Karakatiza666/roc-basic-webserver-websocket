# roc-basic-webserver-websocket

A WebSocket client for [basic-webserver](https://github.com/roc-lang/basic-webserver)
0.20.0, built on [roc-websocket](https://github.com/Karakatiza666/roc-websocket). Use it inside a request
handler to talk to a WebSocket server and answer over HTTP.

```roc
app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.22.0/BM2BUXA8mwbcoKPUfRV8cLtsUdnsSBPwjNLPRUJQAQ7Q.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.7/EBNZjRmQ5PZiJAE5UMUFePtQFdb1FnsQX1qagVuiCwM9.tar.zst",
	bws_ws: "https://github.com/Karakatiza666/roc-basic-webserver-websocket/releases/download/0.0.4/CVdw532jo8EfTqYFZjfGismeWHjfuVPTfj6ofaKGcAmU.tar.zst",
}

import ws.Ws
import bws_ws.WsClient

ask! : Str => Try(Ws.Message, WsClient.Error)
ask! = |text| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/", protocols: ["echo"] })?
	sent = opened.conn.send!(Text(text))?
	(conn, reply) = sent.receive!()?
	_ = Ws.close_and_wait!(WsClient.ops, conn, 1000, "")?
	Ok(reply)
}
```

The app must name exactly the platform URL above (one platform per build).
Each call returns the updated connection: keep using the newest one.

## API

- `WsClient.connect! : Ws.ConnectRequest => Try(Ws.Opened(WsClient.Conn), WsClient.Error)`
- `WsClient.Conn = Client.Conn(WsClient.Link, WsClient.Errors)`, with the methods
  `send!`, `receive!`, `poll!`, `close!`, `ping!`, `pong!`, `send_frame!`,
  `receive_frame!`.
- `WsClient.ops : Client.Ops(WsClient.Link, WsClient.Errors)`, the same as a
  record (`Ws.Raw` and `Ws.Poll`), for code generic over features such as
  `Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`.
- `WsClient.Errors = [Tcp(Str), Connect(Str), Entropy(Str)]`, the platform's
  tags; `WsClient.Error = Client.Error(WsClient.Errors)` is the whole error union.
- `WsClient.connect`, the `Ws.Connect` feature record.
- `WsClient.link!`, `WsClient.transport`, `WsClient.random_bytes!`: the parts.

Every error row is `[Closed(Ws.Closure), Closing, ..e]`: `Closed` once the
connection has ended, `Closing` from `send!` and the other senders after
`close!` while the closing handshake is under way (`receive!` still delivers the
messages on their way, then ends with `Closed`). `opened.extensions` is
`Reported(list)` (this client gives `Reported([])`) or `NotReported`.

## Limitations

- **Client only.** basic-webserver cannot answer an upgrade (it refuses 1xx
  responses and `Upgrade`/`Connection` headers), so there is no server side.
- **Within one handler.** A connection lives inside one `respond!` call or one
  SSE transition; nothing keeps it across requests.
- **`ws://` only.** The platform's Tcp has no TLS. `wss://` is `Refused`.
- **30 s deadline per read, not configurable.** The host sets it on the
  socket for each `read_up_to!`. The adapter reports it as the link's
  `TimedOut`, not as an error: `receive!` keeps waiting through it, and `poll!`
  returns `TimedOut` when 30 s pass with no bytes. The connection keeps every
  byte read so far, so nothing is lost. A write has its own 30 s deadline as a
  whole, and the connect one too; those are network errors
  (`Tcp("ErrorKind::TimedOut")`, `Connect("ErrorKind::TimedOut")`), and the
  connection should be dropped.
- **A client inside a request cannot outlive the platform's limits.** The host
  puts no total limit on a handler (checked: a handler that waits 70 s on
  `receive!` answers after 70 s), but the HTTP caller's or a proxy's timeout
  ends the request, and a shutdown drains handlers for at most 30 s (by
  default) before it forces the exit.
- **No `receive_within!`.** No read can be held under 30 s and the only clock
  is wall time (`UnixTime`), so a deadline of `ms` could be missed by up to
  30 s; the adapter does not claim `Ws.ReceiveWithin`. `poll!` is an idle
  deadline: any frame, a Ping included, restarts it, so a peer that pings
  keeps it from timing out. A program that needs a deadline for data messages
  needs [roc-basic-cli-websocket](https://github.com/Karakatiza666/roc-basic-cli-websocket)
  or the Cloudflare Workers adapter.
- **`StreamBusy`.** Two handlers using one connection at once get
  `Tcp("StreamBusy")`.
- At most 64 Tcp streams and 64 file readers open at once (each connection holds
  one of each).

## Randomness

basic-webserver has no random effect. The adapter opens `/dev/urandom` once per
connection through `File` and reads it by lines (the only way the platform reads
files). It drops each newline, gathers at least 48 bytes (each uniform over the
255 values other than 10, over 383 bits in all) and takes their SHA-256 as 32
output bytes. The output is as good as the kernel's CSPRNG for masks and keys;
it needs a Unix `/dev/urandom` (Linux, macOS), not Windows.

## Changes

### 0.0.4

No API changes.

| Dependency | Before | Now |
| --- | --- | --- |
| basic-webserver | 0.21.0 | 0.22.0 |
| roc-websocket | 0.0.6 | 0.0.7 |
| Roc (`.roc-version`) | `nightly-2026-11-07-ad3a5d2` | `nightly-2026-11-15-f25da45` |

basic-webserver 0.22.0 is built on Roc `nightly-2026-11-15-f25da45`, and it
gives no warnings on that nightly. Every adapter of a program must use the
same roc-websocket version. roc-basic-cli-websocket 0.0.5 also uses
roc-websocket 0.0.7.

### 0.0.3

No API changes.

| Dependency | Before | Now |
| --- | --- | --- |
| basic-webserver | 0.20.0 | 0.21.0 |
| roc-websocket | 0.0.5 | 0.0.6 |
| Roc (`.roc-version`) | `nightly-2026-11-03-34bd006` | `nightly-2026-11-07-ad3a5d2` |

basic-webserver 0.21.0 needs Roc `nightly-2026-11-06-34f137a` or newer.
Every adapter of a program must use the same roc-websocket version.
roc-basic-cli-websocket 0.0.4 also uses roc-websocket 0.0.6.

### 0.0.2

Moved to roc-websocket 0.0.5, which this client-only adapter needs no code
change for (`WsClient` is unchanged; the 0.0.5 changes to `Ws.Handlers` and
`Ws.drive!` affect only code that runs them over a connection: `on_close!` now
gets the connection and `drive!` returns the state). Every adapter of a program must use the same
roc-websocket version, so the dependency is now 0.0.5, as in
roc-basic-cli-websocket 0.0.3.

Documented, not changed: what bounds time on this platform (see Limitations)
and why there is no `receive_within!`.

Tested on Roc `nightly-2026-11-03-34bd006` (the pin in `.roc-version`) with
basic-webserver 0.20.0, which was built with the 11-01 nightly.

### 0.0.1

The first release: a client over `pf.Tcp`, for roc-websocket 0.0.4.

## Checks

```sh
ROC=/path/to/roc scripts/all_tests.sh          # fmt, check
ROC=/path/to/roc scripts/all_tests.sh --e2e    # also a live run against tests/echo_server.py
```

`examples/client.roc` serves `/echo` (the Python stdlib test server in `tests/`),
`/slow` (`poll!` across the 30 s deadline) and `/surreal` (a JSON `ping` RPC to SurrealDB at
`ws://127.0.0.1:8000/rpc`).

The release URL (`<hash>` above) is printed by `scripts/bundle.sh 0.0.4` and in the
release notes of each [release](https://github.com/Karakatiza666/roc-basic-webserver-websocket/releases).

```sh
ROC=/path/to/roc scripts/bundle.sh 0.0.4  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # checks the examples against the bundle
```
