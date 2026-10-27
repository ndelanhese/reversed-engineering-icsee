"""Synthetic camera-shaped HEVC RTSP/TCP peer, including Digest and Sofia auth.

Run two instances, the second with --require-sofia-query, and adb reverse their
ports. RtspCompatibilityTest takes digestRtspPort and sofiaRtspPort. The public,
test-only credentials below deliberately exercise URI reserved characters.
An additional --audio-leads instance uses audioFirstRtspPort and models cameras
that stop the entire session when the client tears down the audio track.
No camera recordings, identifiers, or captured authentication headers are used.
"""
import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import socketserver
import struct
import threading
from urllib.parse import unquote, urlsplit

USERNAME = "fixture"
PASSWORD = "syn:the@tic/?#%&=+"
REALM = "Synthetic HEVC fixture"
NONCE = "synthetic-nonce-0123456789"
SESSION = "synthetic-session"
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


def md5(value):
    return hashlib.md5(value.encode()).hexdigest()


def sofia_password(value):
    digest = hashlib.md5(value.encode()).digest()
    return "".join(ALPHABET[(digest[i] + digest[i + 1]) % 62] for i in range(0, 16, 2))


raw = (Path(__file__).parent / "Fixtures/recording-synthetic.h265").read_bytes()
nals = [nal for nal in re.split(b"\x00\x00\x00?\x01", raw) if nal]
parameter_sets = {kind: next(n for n in nals if n[0] >> 1 & 63 == kind) for kind in (32, 33, 34)}
frames = []
for nal in nals:
    if nal[0] >> 1 & 63 == 35:  # An access unit delimiter starts each synthetic frame.
        frames.append([])
    if frames:
        frames[-1].append(nal)
assert len(frames) == 30 and all(any(n[0] >> 1 & 63 < 32 for n in frame) for frame in frames)


def payloads(nal, mtu):
    """RFC 7798 single-NAL or type-49 FU; no DONL was negotiated in SDP."""
    if len(nal) <= mtu:
        yield nal
        return
    indicator = bytes([(nal[0] & 0x81) | (49 << 1), nal[1]])
    kind = nal[0] >> 1 & 63
    chunks = [nal[i:i + mtu - 3] for i in range(2, len(nal), mtu - 3)]
    for i, chunk in enumerate(chunks):
        yield indicator + bytes([kind | (0x80 if i == 0 else 0) | (0x40 if i == len(chunks) - 1 else 0)]) + chunk


class Peer(socketserver.StreamRequestHandler):
    def handle(self):
        self.lock = threading.Lock()
        self.done = threading.Event()
        self.sender = None
        self.channels = {}
        self.authenticated = False
        self.base_uri = None
        try:
            while first := self.rfile.read(1):
                if first == b"$":
                    header = self.rfile.read(3)
                    if len(header) != 3:
                        break
                    self.rfile.read(struct.unpack("!H", header[1:])[0])
                    continue
                method, uri, _ = (first + self.rfile.readline()).decode().strip().split(" ", 2)
                headers = {}
                while (line := self.rfile.readline()) not in (b"\r\n", b""):
                    key, value = line.decode().split(":", 1)
                    headers[key.lower()] = value.strip()
                self.rfile.read(int(headers.get("content-length", "0")))
                self.dispatch(method, uri, headers)
                if method == "TEARDOWN":
                    self.server.event("session_teardown", audio_track="trackID=4" in uri)
                    break
        except (ConnectionError, OSError, ValueError):
            pass
        finally:
            self.done.set()
            if self.sender:
                self.sender.join(timeout=2)

    def respond(self, headers, code=200, extra="", body=b""):
        reason = {200: "OK", 401: "Unauthorized", 404: "Not Found", 455: "Method Not Valid in This State", 461: "Unsupported Transport"}[code]
        data = (f"RTSP/1.0 {code} {reason}\r\nCSeq: {headers.get('cseq', '1')}\r\n"
                f"{extra}Content-Length: {len(body)}\r\n\r\n").encode() + body
        with self.lock:
            self.request.sendall(data)

    def valid_digest(self, method, uri, header):
        if not header.startswith("Digest "):
            return False
        fields = dict(re.findall(r'(\w+)="([^"\\]*)"', header[7:]))
        mismatches = [key for key, value in {
            "username": USERNAME, "realm": REALM, "nonce": NONCE,
        }.items() if fields.get(key) != value]
        auth_uri = fields.get("uri", "")
        # LIVE555 signs fBaseURL for SETUP, while FFmpeg signs the track URI.
        # Its own RTSPServer verifies the signed header URI. Accept only our
        # authenticated session's exact aggregate base as the alternative.
        session_track = self.authenticated and uri in (self.base_uri + "trackID=3", self.base_uri + "trackID=4")
        if method == "SETUP" and self.authenticated and not session_track:
            mismatches.append("request_uri")
        aggregate_setup = method == "SETUP" and session_track and auth_uri == self.base_uri
        # In the audio-leading camera variant, stopping audio tears down the
        # whole session. LIVE555 also signs this per-track request with its base.
        aggregate_audio_teardown = (self.server.audio_leads and method == "TEARDOWN" and session_track
                                    and uri == self.base_uri + "trackID=4" and auth_uri == self.base_uri)
        if auth_uri != uri and not (aggregate_setup or aggregate_audio_teardown):
            mismatches.append("uri")
        expected = md5(f"{md5(f'{USERNAME}:{REALM}:{PASSWORD}')}:{NONCE}:{md5(f'{method}:{auth_uri}')}")
        matches = hmac.compare_digest(fields.get("response", "").lower(), expected)
        if mismatches or not matches:
            self.server.event("digest_rejected", method=method, mismatches=mismatches, response_valid=matches)
        return not mismatches and matches

    def dispatch(self, method, uri, headers):
        if method == "OPTIONS":
            self.respond(headers, extra="Public: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN\r\n")
            return
        if not self.valid_digest(method, uri, headers.get("authorization", "")):
            self.server.event("digest_challenge", method=method)
            self.respond(headers, 401, f'WWW-Authenticate: Digest realm="{REALM}", nonce="{NONCE}"\r\n')
            return
        if method == "DESCRIBE":
            # The vendor app puts password= in its path, before ?real_stream.
            parts = urlsplit(uri)
            has_sofia = f"&password={sofia_password(PASSWORD)}&" in unquote(parts.path)
            if self.server.require_sofia and not has_sofia:
                self.server.event("sofia_required")
                self.respond(headers, 401, f'WWW-Authenticate: Digest realm="{REALM}", nonce="{NONCE}"\r\n')
                return
            self.authenticated = True
            self.server.event("digest_accepted", sofia=has_sofia)
            props = {kind: base64.b64encode(nal).decode() for kind, nal in parameter_sets.items()}
            body = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=Synthetic HEVC fixture\r\n"
                    "c=IN IP4 127.0.0.1\r\nt=0 0\r\na=control:*\r\na=range:npt=0-\r\n"
                    "m=video 0 RTP/AVP 98\r\na=rtpmap:98 H265/90000 \r\n"
                    f"a=fmtp:98 profile-id=1;sprop-pps={props[34]};sprop-sps={props[33]};sprop-vps={props[32]};\r\n"
                    "a=control:trackID=3\r\nm=audio 0 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\na=control:trackID=4\r\n").encode()
            # Keep ?real_stream out of the base so relative tracks resolve honestly.
            base = uri.split("?", 1)[0].rstrip("/") + "/"
            self.base_uri = base
            self.respond(headers, extra=f"Content-Type: application/sdp\r\nContent-Base: {base}\r\n", body=body)
        elif method == "SETUP":
            transport = headers.get("transport", "")
            pair = re.search(r"interleaved=(\d+)-(\d+)", transport)
            track = re.search(r"trackID=([34])(?:$|[?])", uri)
            if not self.authenticated:
                self.respond(headers, 455)
            elif "RTP/AVP/TCP" not in transport or not pair:
                self.respond(headers, 461)
            elif not track:
                self.respond(headers, 404)
            else:
                channel, rtcp = map(int, pair.groups())
                self.channels[int(track[1])] = channel
                self.server.event("setup", track=int(track[1]), channel=channel,
                                  aggregate_digest=dict(re.findall(r'(\w+)="([^"\\]*)"', headers["authorization"][7:])).get("uri") == self.base_uri)
                session = f"{SESSION}-track-{track[1]}" if self.server.audio_leads else SESSION
                self.respond(headers, extra=f"Transport: RTP/AVP/TCP;unicast;interleaved={channel}-{rtcp}\r\nSession: {session}\r\n")
        elif method == "PLAY":
            if 3 not in self.channels:
                self.respond(headers, 455)
                return
            self.respond(headers, extra=f"Session: {SESSION}\r\nRange: npt=0.000-\r\n")
            self.server.event("play", audio_leads=self.server.audio_leads)
            if self.sender is None:
                self.sender = threading.Thread(target=self.stream, daemon=True)
                self.sender.start()
        else:
            self.respond(headers, extra=f"Session: {SESSION}\r\n")

    def send_rtp(self, channel, payload_type, sequence, timestamp, payload, marker=False):
        packet = struct.pack("!BBHII", 128, payload_type | (128 if marker else 0), sequence & 65535,
                             timestamp & 0xffffffff, 1234 + channel) + payload
        with self.lock:
            self.request.sendall(bytes([36, channel]) + struct.pack("!H", len(packet)) + packet)

    def stream(self):
        sequence = 0
        audio_sequence = 0
        timestamp = 0
        try:
            if self.server.audio_leads and 4 in self.channels:
                self.server.event("audio_lead_started")
                # Let the client discover PCMA before any HEVC packet arrives.
                # The real-camera failure occurs when :no-audio then stops track4.
                for _ in range(15):
                    if self.done.is_set():
                        return
                    self.send_rtp(self.channels[4], 8, audio_sequence, timestamp * 8000 // 90000, b"\xd5" * 800)
                    audio_sequence += 1
                    timestamp += 9000
                    self.done.wait(0.1)
                self.server.event("video_started")
            while not self.done.is_set():
                for frame in frames:
                    if self.done.is_set():
                        return
                    for index, nal in enumerate(frame):
                        packets = list(payloads(nal, self.server.mtu))
                        for fragment, payload in enumerate(packets):
                            self.send_rtp(self.channels[3], 98, sequence, timestamp, payload,
                                          index == len(frame) - 1 and fragment == len(packets) - 1)
                            sequence += 1
                    if 4 in self.channels:
                        self.send_rtp(self.channels[4], 8, audio_sequence, timestamp * 8000 // 90000, b"\xd5" * 800)
                        audio_sequence += 1
                    timestamp += 9000  # 10fps synthetic source, no reordered frames.
                    self.done.wait(0.1)
        except (ConnectionError, OSError):
            self.done.set()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    @staticmethod
    def event(event, **fields):
        # Protocol evidence without URLs or authentication material.
        print(json.dumps({"event": event, **fields}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--require-sofia-query", action="store_true")
    parser.add_argument("--audio-leads", action="store_true", help="PCMA leads HEVC by 1.5s; audio TEARDOWN closes session")
    parser.add_argument("--mtu", type=int, default=500, help="HEVC payload bytes; forces FU coverage")
    args = parser.parse_args()
    if not 4 <= args.mtu <= 1400:
        parser.error("mtu must be between 4 and 1400")
    with Server(("127.0.0.1", args.port), Peer) as server:
        server.require_sofia = args.require_sofia_query
        server.audio_leads = args.audio_leads
        server.mtu = args.mtu
        print(json.dumps({"port": server.server_address[1], "requireSofia": args.require_sofia_query,
                          "audioLeads": args.audio_leads}), flush=True)
        server.serve_forever()
