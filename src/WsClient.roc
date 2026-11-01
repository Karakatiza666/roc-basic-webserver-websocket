import pf.Tcp
import pf.File
import pf.Path
import ws.Ws
import ws.Client
import ws.Handshake

## WebSocket clients for basic-webserver 0.19.0, over `pf.Tcp` and the pure
## client of roc-websocket.
##
## Plain `ws://` only (the platform's Tcp has no TLS), and only within one
## request handler or one SSE transition: basic-webserver has no WebSocket
## server and no way to keep a connection across requests.
##
## Limits from the platform:
## - Every Tcp read has a 30 s host deadline. `receive!` keeps waiting across
##   it; `poll!` returns `TimedOut` when it passes with no message. The connection
##   keeps every byte read, so a deadline never loses data.
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
	dial : Ws.Connect(WsClient.Conn, Client.Errors(WsClient.Errors), {})
	dial = { connect!: WsClient.connect! }

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
