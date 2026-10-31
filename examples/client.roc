## Opens a WebSocket inside one request handler and answers over HTTP.
##
##   GET /echo?port=9001  talks to an echo server on 127.0.0.1 (the test
##                        server in the repo README) and reports each step.
##   GET /slow            asks the echo server on 9001 to wait 35 s: the first
##                        `receive!` times out after 30 s, the second gets it.
##   GET /surreal         sends a JSON `ping` RPC to SurrealDB at
##                        ws://127.0.0.1:8000/rpc and returns the reply.
app [Context, program] {
	bws_ws: "../src/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	pf: platform "https://github.com/roc-lang/basic-webserver/releases/download/0.19.0/4KBAoiBazDfi9UF6e3BYKwon6rA8mnx3dbLMLKFzdEMw.tar.zst",
	ws: "../../roc-websocket/src/main.roc",
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
	conn = opened.conn
	var $lines = ["connected, subprotocol \"${opened.protocol}\""]

	(conn.send!)(Text("hello from basic-webserver"))?
	$lines = $lines.append("echo: ${show((conn.receive!)({})?)}")

	(conn.send!)(Binary([1, 2, 3, 250]))?
	$lines = $lines.append("echo: ${show((conn.receive!)({})?)}")

	(conn.send!)(Text("fragment-me"))?
	$lines = $lines.append("assembled: ${show((conn.receive!)({})?)}")

	(conn.send!)(Text("ping-me"))?
	$lines = $lines.append("after a server ping: ${show((conn.receive!)({})?)}")

	(conn.send!)(Text("big:70000"))?
	$lines = $lines.append("big: ${show((conn.receive!)({})?)}")

	# Our own fragmented message, sent frame by frame.
	(conn.send_frame!)({ fin: Bool.False, opcode: Text, payload: "sent in ".to_utf8() })?
	(conn.send_frame!)({ fin: Bool.True, opcode: Continuation, payload: "two frames".to_utf8() })?
	$lines = $lines.append("echo of fragments: ${show((conn.receive!)({})?)}")

	(conn.ping!)("roc".to_utf8())?
	pong = (conn.receive_frame!)({})?
	$lines = $lines.append("pong frame: ${Str.inspect(pong.opcode)} \"${Str.from_utf8(pong.payload) ?? "?"}\"")

	closure = (conn.close!)(1000, "done")?
	$lines = $lines.append("closed: ${Str.inspect(closure)}")

	# A second connection, closed by the server.
	second = WsClient.connect!({ url: "ws://127.0.0.1:${if (port == "") "9001" else port}/" })?
	(second.conn.send!)(Text("close-me"))?
	ended = match (second.conn.receive!)({}) {
		Err(Closed(c)) => "server closed: ${Str.inspect(c)}"
		Ok(m) => "unexpected message ${show(m)}"
		Err(other) => return Err(other)
	}
	$lines = $lines.append(ended)
	Ok("${Str.join_with($lines, "\n")}\n")
}

## A JSON `ping` RPC to SurrealDB.
surreal! : {} => Try(Str, WsClient.Error)
surreal! = |{}| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:8000/rpc", protocols: ["json"] })?
	(opened.conn.send!)(Text("{\"id\":1,\"method\":\"ping\"}"))?
	reply = (opened.conn.receive!)({})?
	(opened.conn.send!)(Text("{\"id\":2,\"method\":\"version\"}"))?
	version = (opened.conn.receive!)({})?
	closure = (opened.conn.close!)(1000, "")?
	Ok("subprotocol \"${opened.protocol}\"\nping reply: ${show(reply)}\nversion reply: ${show(version)}\nclosed: ${Str.inspect(closure)}\n")
}

## A reply after the platform's 30 s read deadline.
slow! : {} => Try(Str, WsClient.Error)
slow! = |{}| {
	opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/" })?
	(opened.conn.send!)(Text("sleep:35"))?
	first = match (opened.conn.receive!)({}) {
		Err(TimedOut) => "first receive: TimedOut"
		Ok(m) => "first receive: ${show(m)}"
		Err(other) => return Err(other)
	}
	second = (opened.conn.receive!)({})?
	_ = (opened.conn.close!)(1000, "")?
	Ok("${first}\nsecond receive: ${show(second)}\n")
}
