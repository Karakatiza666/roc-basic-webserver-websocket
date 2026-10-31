# roc-basic-webserver-websocket

A WebSocket client for [basic-webserver](https://github.com/roc-lang/basic-webserver)
0.19.0, built on [roc-websocket](https://github.com/Karakatiza666/roc-websocket). Use it inside a request
handler to talk to a WebSocket server and answer over HTTP.

```roc
app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoiBazDfi9UF6e3BYKwon6rA8mnx3dbLMLKFzdEMw.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.1/4i6sgv5VVbr9xet5sWkRWMYa4H3dMUJSzWrMhRXsFTgn.tar.zst",
	bws_ws: "https://github.com/Karakatiza666/roc-basic-webserver-websocket/releases/download/0.0.1/<hash>.tar.zst",
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

- `WsClient.connect! : Ws.Request => Try(Ws.Opened(WsClient.Conn), WsClient.Error)`
- `WsClient.Conn = Client.Conn(WsClient.Link, WsClient.Errors)`, with the methods
  `send!`, `receive!`, `poll!`, `close!`, `ping!`, `pong!`, `send_frame!`,
  `receive_frame!`.
- `WsClient.ops : Client.Ops(WsClient.Link, WsClient.Errors)`, the same as a
  record (`Ws.Raw` and `Ws.Poll`), for code generic over features such as
  `Ws.close_and_wait!`, `Ws.drive!`, `Ws.messages`.
- `WsClient.Errors = [Tcp(Str), Connect(Str), Entropy(Str)]`, the platform's
  tags; `WsClient.Error = Client.Error(WsClient.Errors)` is the whole error union.
- `WsClient.dial`, the `Ws.Dial` feature record.
- `WsClient.link!`, `WsClient.link_ops`, `WsClient.random_bytes!`: the parts.

## Limitations

- **Client only.** basic-webserver cannot answer an upgrade (it refuses 1xx
  responses and `Upgrade`/`Connection` headers), so there is no server side.
- **Within one handler.** A connection lives inside one `respond!` call or one
  SSE transition; nothing keeps it across requests.
- **`ws://` only.** The platform's Tcp has no TLS. `wss://` is `Refused`.
- **30 s deadline per read.** `receive!` keeps waiting through it. `poll!`
  returns `Idle` when 30 s pass with no message, and the connection keeps every
  byte read so far, so nothing is lost.
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

## Checks

```sh
ROC=/path/to/roc scripts/all_tests.sh          # fmt, check
ROC=/path/to/roc scripts/all_tests.sh --e2e    # also a live run against tests/echo_server.py
```

`examples/client.roc` serves `/echo` (the Python stdlib test server in `tests/`),
`/slow` (`poll!` across the 30 s deadline) and `/surreal` (a JSON `ping` RPC to SurrealDB at
`ws://127.0.0.1:8000/rpc`).

The release URL (`<hash>` above) is printed by `scripts/bundle.sh 0.0.1` and in the
release notes of each [release](https://github.com/Karakatiza666/roc-basic-webserver-websocket/releases).

```sh
ROC=/path/to/roc scripts/bundle.sh 0.0.1  # dist/<hash>.tar.zst and its release URL
ROC=/path/to/roc scripts/test_bundle.sh   # checks the examples against the bundle
```
