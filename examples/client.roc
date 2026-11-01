## Opens a WebSocket inside one request handler and answers over HTTP.
##
##   GET /echo?port=9001  talks to an echo server on 127.0.0.1 (the test
##                        server in the repo README) and reports each step.
##   GET /slow            asks the echo server on 9001 to wait 35 s: the first
##                        `poll!` gives Idle after 30 s, the second the reply.
##   GET /surreal         sends a JSON `ping` RPC to SurrealDB at
##                        ws://127.0.0.1:8000/rpc and returns the reply.
app [Context, program] {
	bws_ws: "../src/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoiBazDfi9UF6e3BYKwon6rA8mnx3dbLMLKFzdEMw.tar.zst",
	ws: "https://github.com/Karakatiza666/roc-websocket/releases/download/0.0.2/8ruw5bazzn7Xrtd3nGUTv5aGRVg3tSskgxeWbyGYsFZL.tar.zst",
}

import pf.Server
import http.Response
import ws.Ws
import bws_ws.WsClient

Context : {}

program = { init!, respond!, shutdown! }

init! : () => Try({ config : Server.Config, context : Context }, [Exit(I64)])
init! = || Ok({ config: Server.default_config.with_listen({ host: "127.0.0.1", port: 8088 }), context: {} })

shutdown! : Server.ShutdownReason, Context => Try({}, [Exit(I64)])
shutdown! = |_reason, _context| Ok({})

respond! : Server.Request, Context => Try(Server.Outcome, [ServerErr(Str)])
respond! = |request, _context| {
	(path, query) =
		match request.target() {
			Resource({ raw_path, raw_query: Present(q) }) => (raw_path, q)
			Resource({ raw_path, raw_query: Absent }) => (raw_path, "")
			_ => ("", "")
		}
	result =
		match path {
			"/echo" => echo!(query.drop_prefix("port="))
			"/surreal" => surreal!({})
			"/slow" => slow!({})
			_ => Ok("try /echo or /surreal\n")
		}
	(status, body) =
		match result {
			Ok(text) => (200, text)
			Err(err) => (502, "WebSocket failed: ${Str.inspect(err)}\n")
		}
	Ok(Server.respond(Response.from_status(status).add_header("Content-Type", "text/plain; charset=utf-8").with_body(body.to_utf8())))
}

show : Ws.Message -> Str
show = |message| match message {
	Text(s) => "Text(\"${s}\")"
	Binary(b) => "Binary(${b.len().to_str()} bytes)"
}

## Each step of a session with the test echo server, as lines of text.
echo! : Str => Try(Str, WsClient.Error)
echo! = |port| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:${if (port == "") "9001" else port}/chat?room=1", protocols: ["chat", "echo"] })?
	extensions =
		match opened.extensions {
			Reported(list) => "${list.len().to_str()} reported"
			NotReported => "not reported"
		}
	var $lines = ["connected, subprotocol \"${opened.protocol}\", extensions ${extensions}"]

	# Each call returns the updated connection.
	exchange! = |conn, message| {
		sent = conn.send!(message)?
		sent.receive!()
	}

	(c1, m1) = exchange!(opened.conn, Text("hello from basic-webserver"))?
	$lines = $lines.append("echo: ${show(m1)}")
	(c2, m2) = exchange!(c1, Binary([1, 2, 3, 250]))?
	$lines = $lines.append("echo: ${show(m2)}")
	(c3, m3) = exchange!(c2, Text("fragment-me"))?
	$lines = $lines.append("assembled: ${show(m3)}")
	(c4, m4) = exchange!(c3, Text("ping-me"))?
	$lines = $lines.append("after a server ping: ${show(m4)}")
	(c5, m5) = exchange!(c4, Text("big:70000"))?
	$lines = $lines.append("big: ${show(m5)}")

	# Our own fragmented message, sent frame by frame.
	c6 = c5.send_frame!({ fin: Bool.False, opcode: Text, payload: "sent in ".to_utf8() })?
	c7 = c6.send_frame!({ fin: Bool.True, opcode: Continuation, payload: "two frames".to_utf8() })?
	(c8, m6) = c7.receive!()?
	$lines = $lines.append("echo of fragments: ${show(m6)}")

	c9 = c8.ping!("roc".to_utf8())?
	(c10, pong) = c9.receive_frame!()?
	$lines = $lines.append("pong frame: ${Str.inspect(pong.opcode)} \"${Str.from_utf8(pong.payload) ?? "?"}\"")

	# close! starts the close; receive! finishes it.
	c11 = c10.close!(1000, "done")?
	# Until the close completes, a send gives Closing.
	closing = match c11.send!(Text("late")) {
		Err(Closing) => "send while closing: Closing"
		_ => "send while closing: unexpected"
	}
	$lines = $lines.append(closing)
	closed = match c11.receive!() {
		Err(Closed(c)) => "closed: ${Str.inspect(c)}"
		Ok((_, m)) => "unexpected message ${show(m)}"
		Err(other) => return Err(other)
	}
	$lines = $lines.append(closed)

	# A second connection, closed by the server.
	second = WsClient.connect!({ url: "ws://127.0.0.1:${if (port == "") "9001" else port}/" })?
	s1 = second.conn.send!(Text("close-me"))?
	ended = match s1.receive!() {
		Err(Closed(c)) => "server closed: ${Str.inspect(c)}"
		Ok((_, m)) => "unexpected message ${show(m)}"
		Err(other) => return Err(other)
	}
	$lines = $lines.append(ended)
	Ok("${Str.join_with($lines, "\n")}\n")
}

## A JSON `ping` RPC to SurrealDB, through the generic helpers of `Ws` over
## the adapter's operations record.
surreal! : {} => Try(Str, WsClient.Error)
surreal! = |{}| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:8000/rpc", protocols: ["json"] })?
	ops = WsClient.ops
	c1 = (ops.send!)(opened.conn, Text("{\"id\":1,\"method\":\"ping\"}"))?
	(c2, reply) = (ops.receive!)(c1)?
	c3 = (ops.send!)(c2, Text("{\"id\":2,\"method\":\"version\"}"))?
	(c4, version) = (ops.receive!)(c3)?
	closure = Ws.close_and_wait!(ops, c4, 1000, "")?
	Ok("subprotocol \"${opened.protocol}\"\nping reply: ${show(reply)}\nversion reply: ${show(version)}\nclosed: ${Str.inspect(closure)}\n")
}

## A reply after the platform's 30 s read deadline: `poll!` gives `Idle`, the
## connection keeps its state, and the next `poll!` gets the reply.
slow! : {} => Try(Str, WsClient.Error)
slow! = |{}| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/" })?
	c1 = opened.conn.send!(Text("sleep:35"))?
	(c2, first) = c1.poll!()?
	(c3, second) = c2.poll!()?
	_ = Ws.close_and_wait!(WsClient.ops, c3, 1000, "")?
	Ok("first poll: ${Str.inspect(first)}\nsecond poll: ${Str.inspect(second)}\n")
}
