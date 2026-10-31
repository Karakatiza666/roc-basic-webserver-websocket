# roc-basic-webserver-websocket

A WebSocket client for [basic-webserver](https://github.com/roc-lang/basic-webserver)
0.19.0, built on [roc-websocket](../roc-websocket). Use it inside a request
handler to talk to a WebSocket server and answer over HTTP.

```roc
app [Context, program] {
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoiBazDfi9UF6e3BYKwon6rA8mnx3dbLMLKFzdEMw.tar.zst",
	ws: "../roc-websocket/src/main.roc",
	bws_ws: "../roc-basic-webserver-websocket/src/main.roc",
}

import ws.Ws
import bws_ws.WsClient

ask! : Str => Try(Ws.Message, WsClient.Error)
ask! = |text| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/", protocols: ["echo"] })?
	(opened.conn.send!)(Text(text))?
	reply = (opened.conn.receive!)({})?
	_ = (opened.conn.close!)(1000, "")?
	Ok(reply)
}
```

The app must name exactly the platform URL above (one platform per build).

## API

- `WsClient.connect! : Ws.Request => Try(Ws.Opened(WsClient.Conn), WsClient.Error)`
- `WsClient.Conn = Client.Conn(WsClient.Errors)`: `send!`, `receive!`,
  `close!`, `ping!`, `pong!`, `send_frame!`, `receive_frame!` (`Ws.Raw`).
- `WsClient.Errors = [Tcp(Str), Connect(Str), Entropy(Str)]`, the platform's
  tags; `WsClient.Error` is the whole closed error union.
- `WsClient.dial`, the `Ws.Dial` feature record.
- `WsClient.link!`, `WsClient.random_bytes!`: the parts, for other drivers.

## Limitations

- **Client only.** basic-webserver cannot answer an upgrade (it refuses 1xx
  responses and `Upgrade`/`Connection` headers), so there is no server side.
- **Within one handler.** A connection lives inside one `respond!` call or one
  SSE transition; nothing keeps it across requests.
- **`ws://` only.** The platform's Tcp has no TLS. `wss://` is `Refused`.
- **30 s deadline per read.** A `receive!` with no frame start for 30 s returns
  `Err(TimedOut)`; the connection stays usable and the next `receive!` continues.
  Inside a frame or a fragmented message the client keeps waiting.
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
`/slow` (the 30 s timeout) and `/surreal` (a JSON `ping` RPC to SurrealDB at
`ws://127.0.0.1:8000/rpc`).

`roc bundle` refuses this package while it depends on roc-websocket by path;
release roc-websocket first and use its URL.
