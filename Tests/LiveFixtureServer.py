"""Loopback-only RTSP/TCP peer serving repository-owned synthetic H.264."""
import base64
import json
from pathlib import Path
import re
import socketserver
import struct
import threading

raw = (Path(__file__).parent / "Fixtures/pattern.h264").read_bytes()
nals = [nal for nal in re.split(b"\x00\x00\x00?\x01", raw) if nal]
sps = next(n for n in nals if n[0] & 31 == 7)
pps = next(n for n in nals if n[0] & 31 == 8)
# Repeat independently decodable frames; no real camera or credentials involved.
frames = [n for n in nals if n[0] & 31 == 5]
assert frames, "Synthetic fixture must include an IDR"

class Peer(socketserver.StreamRequestHandler):
    def handle(self):
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.sender = None
        try:
            while first := self.rfile.read(1):
                # RTCP shares this TCP socket with RTSP requests.
                if first == b"$":
                    header = self.rfile.read(3)
                    if len(header) != 3: break
                    self.rfile.read(struct.unpack("!H", header[1:])[0])
                    continue
                line = first + self.rfile.readline()
                method, uri, _ = line.decode().strip().split(" ", 2)
                headers = {}
                while (line := self.rfile.readline()) not in (b"\r\n", b""):
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                size = int(headers.get("content-length", "0"))
                if size: self.rfile.read(size)
                extra = ""
                body = b""
                if method == "OPTIONS":
                    extra = "Public: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN\r\n"
                elif method == "DESCRIBE":
                    props = ",".join(base64.b64encode(n).decode() for n in [sps, pps])
                    body = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Synthetic fixture\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\na=control:*\r\n"
                            "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\n"
                            f"a=fmtp:96 packetization-mode=1;sprop-parameter-sets={props}\r\na=control:trackID=0\r\n").encode()
                    extra = f"Content-Type: application/sdp\r\nContent-Base: {uri}/\r\n"
                elif method == "SETUP":
                    extra = "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\nSession: fixture\r\n"
                else:
                    extra = "Session: fixture\r\n"
                response = f"RTSP/1.0 200 OK\r\nCSeq: {headers.get('cseq', '1')}\r\n{extra}Content-Length: {len(body)}\r\n\r\n".encode() + body
                with self.lock: self.request.sendall(response)
                if method == "PLAY" and self.sender is None:
                    self.sender = threading.Thread(target=self.stream, daemon=True)
                    self.sender.start()
                if method == "TEARDOWN": break
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            self.done.set()
            if self.sender: self.sender.join(timeout=2)

    def stream(self):
        sequence = 0
        timestamp = 0
        try:
            while not self.done.is_set():
                for nal in [sps, pps, *frames]:
                    marker = 128 if nal[0] & 31 in (1, 5) else 0
                    packet = struct.pack("!BBHII", 128, 96 | marker, sequence & 65535, timestamp & 0xffffffff, 1234) + nal
                    with self.lock: self.request.sendall(b"$\x00" + struct.pack("!H", len(packet)) + packet)
                    sequence += 1
                    if marker: timestamp += 6000
                self.done.wait(1/15)
        except (ConnectionError, OSError):
            self.done.set()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

with Server(("127.0.0.1", 0), Peer) as server:
    print(json.dumps({"port": server.server_address[1]}), flush=True)
    server.serve_forever()
