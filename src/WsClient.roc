import pf.Tcp
import pf.File
import pf.Path
import ws.Ws
import ws.Client
import ws.Handshake

## WebSocket clients for basic-webserver 0.20.0, over `pf.Tcp` and the pure
## client of roc-websocket.
##
## Plain `ws://` only (the platform's Tcp has no TLS), and only within one
## request handler or one SSE transition: basic-webserver has no WebSocket
## server and no way to keep a connection across requests.
##
## Limits from the platform:
## - Every Tcp read has a 30 s host deadline that the app cannot change: the
##   host sets it on the socket for each `read_up_to!`. The adapter turns it
##   into the link's `TimedOut`, so it is not an error. `receive!` keeps
##   waiting across it; `poll!` returns `TimedOut` when it passes with no
##   bytes. The connection keeps every byte read, so a deadline never loses
##   data. A write has a 30 s deadline as a whole and the connect too; hitting
##   one is a network error (`Tcp("ErrorKind::TimedOut")`,
##   `Connect("ErrorKind::TimedOut")`), and the connection should be dropped.
## - A request handler has no total time limit of its own in the host (a
##   handler that waits for 70 s on `receive!` answers after 70 s). What ends a
##   long handler is outside the app: the HTTP caller's or a proxy's timeout,
##   and the host's shutdown drain (30 s by default), which forces the exit.
##   A WebSocket client inside a request cannot outlive them.
## - There is no `receive_within!` (`Ws.ReceiveWithin`), and it is not added: no
##   read can be held under 30 s, and the only clock is wall time
##   (`UnixTime`), so a deadline of 3 s could be missed by up to 27 s.
##   `poll!` (`Ws.Poll`) is an idle deadline: any frame, a Ping included,
##   restarts it, so a peer that pings keeps it from ever timing out. An app
##   that needs a deadline for data messages needs another platform (basic-cli
##   has `receive_within!`, and so does Cloudflare Workers).
## - One connection used by two handlers at once gives `Tcp("StreamBusy")`.
## - A read materializes at most 8 MiB, so a frame over 8 MiB arrives in
##   several reads (handled), and at most 64 Tcp streams are open at once.
##
## Randomness: the platform has no random effect. The key and the masks come
## from `/dev/urandom`, read through `File` (see `random_bytes!`), so the
## adapter works on Linux and macOS but not on Windows.
WsClient :: [].{

	## The tags this adapter adds: a Tcp failure (`Connect` while connecting),
	## and a failure to read randomness.
	Errors : [Tcp(Str), Connect(Str), Entropy(Str)]

	## The link a connection runs over: the Tcp stream and the randomness
	## reader.
	Link : { tcp : Tcp.Connection, entropy : File.Reader }

	## A connection. Its methods: `send!`, `receive!`, `poll!`, `close!`,
	## `ping!`, `pong!`, `send_frame!`, `receive_frame!`; each returns the
	## updated connection.
	Conn : Client.Conn(WsClient.Link, WsClient.Errors)

	## Every error of a connection and of `connect!`.
	Error : Client.Error(WsClient.Errors)

	## Connect to `request.url` (`ws://host[:port]/path`) and do the handshake.
	##
	## ```roc
	## opened = WsClient.connect!({ url: "ws://127.0.0.1:9001/", protocols: ["echo"] })?
	## conn = opened.conn.send!(Text("hi"))?
	## (conn2, reply) = conn.receive!()?
	## ```
	connect! : Ws.ConnectRequest => Try(Ws.Opened(WsClient.Conn), WsClient.Error)
	connect! = |request| {
		url = Handshake.parse_url(request.url).map_err(|BadUrl(why)| Refused(why))?
		if url.secure {
			return Err(Refused("wss:// needs TLS, which basic-webserver's Tcp does not have"))
		}
		host = url.host.drop_prefix("[").drop_suffix("]")
		tcp = Tcp.connect!(host, url.port).map_err(|err| Connect(Tcp.connect_err_to_str(err)))?
		link = WsClient.link!(tcp)?
		Client.open!(WsClient.transport, link, request)
	}

	## The operations as a record (`Ws.Raw` and `Ws.Poll`), for code generic
	## over features.
	ops : Client.Ops(WsClient.Link, WsClient.Errors)
	ops = Client.ops({})

	## The `Ws.Connect` feature record.
	connect : Ws.Connect(WsClient.Conn, Client.Errors(WsClient.Errors), {})
	connect = { connect!: WsClient.connect! }

	## The byte stream and randomness `Client.open!` needs.
	transport : Client.Transport(WsClient.Link, WsClient.Errors)
	transport = {
		write_bytes!: |link, bytes| {
			link.tcp.write!(bytes).map_err(tcp_error)?
			Ok(link)
		},
		read_up_to!: |link, n| match link.tcp.read_up_to!(n) {
			Ok([]) => Ok((link, End))
			Ok(bytes) => Ok((link, Data(bytes)))
			Err(TcpReadErr(TimedOut)) => Ok((link, TimedOut))
			Err(TcpReadErr(e)) => Err(Tcp(Tcp.stream_err_to_str(e)))
		},
		random_bytes!: |link, n| {
			bytes = WsClient.random_bytes!(link.entropy, n)?
			Ok((link, bytes))
		},
	}

	## The link over a connected Tcp stream. Opens one `/dev/urandom` reader
	## for the connection.
	link! : Tcp.Connection => Try(WsClient.Link, WsClient.Error)
	link! = |tcp| {
		entropy = File.open_reader_with_capacity!(Path.utf8("/dev/urandom"), 256).map_err(|err| Entropy(Str.inspect(err)))?
		Ok({ tcp, entropy })
	}

	## `n` unpredictable bytes from `/dev/urandom`.
	##
	## The platform reads a file only by lines, so each read gives the bytes up
	## to the next newline (byte 10). Those bytes are uniform over the 255
	## values other than 10, about 7.994 bits each. The adapter drops the
	## newline, gathers at least 48 such bytes (over 383 bits of entropy), and
	## takes the SHA-256 of them as 32 output bytes, which removes the bias.
	random_bytes! : File.Reader, U64 => Try(List(U8), WsClient.Error)
	random_bytes! = |reader, n| {
		var $out = []
		while $out.len() < n {
			var $pool = []
			while $pool.len() < 48 {
				line = reader.read_line!().map_err(|err| Entropy(Str.inspect(err)))?
				if line.is_empty() {
					return Err(Entropy("/dev/urandom ended"))
				}
				$pool = $pool.concat(if (line.ends_with([10])) line.drop_last(1) else line)
			}
			$out = $out.concat(Crypto.SHA256.hash($pool).to_bytes())
		}
		Ok($out.take_first(n))
	}
}

tcp_error : [TcpWriteErr(Tcp.StreamErr([]))] -> WsClient.Error
tcp_error = |TcpWriteErr(e)| Tcp(Tcp.stream_err_to_str(e))
