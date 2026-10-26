"""Synthetic loopback recording peer; never connects to cameras or logs credentials."""
import argparse
import json
import signal
import socketserver
import struct
import threading
import time
from pathlib import Path


class State:
    def __init__(self, raw):
        self.raw = raw
        self.lock = threading.Lock()
        self.transfers = {}

    def transfer(self, name, renew=True):
        with self.lock:
            current = self.transfers.get(name)
            if current is None or (renew and current[1].is_set()):
                current = (threading.Event(), threading.Event())
                self.transfers[name] = current
            return current


def frame(session, sequence, message, payload=b""):
    return struct.pack("<BBHIIHHI", 255, 0, 0, session, sequence, 0, message, len(payload)) + payload


class Peer(socketserver.BaseRequestHandler):
    def exact(self, length):
        result = bytearray()
        while len(result) < length:
            chunk = self.request.recv(length - len(result))
            if not chunk:
                raise EOFError
            result.extend(chunk)
        return bytes(result)

    def handle(self):
        # Keep the synthetic connection alive beyond its advertised 30s interval.
        self.request.settimeout(60)
        state = self.server.state
        try:
            while True:
                header = self.exact(20)
                _, _, _, session, sequence, _, message, length = struct.unpack("<BBHIIHHI", header)
                if length > 2 * 1024 * 1024:
                    return
                data = json.loads(self.exact(length).rstrip(b"\x00\n"))
                name = data.get("Name", "")
                reply = {"Ret": 100, "Name": name, "SessionID": "0x00000001"}
                if message == 1000:
                    reply["AliveInterval"] = 30
                elif name == "OPTimeQuery":
                    reply[name] = "2026-10-25 00:01:03"
                elif name == "StorageInfo":
                    reply[name] = [{"PlysicalNo": 0, "PartNumber": 1, "Partition": [{"TotalSpace": "0x4000", "RemainSpace": "0x2000", "Status": 0}]}]
                elif name == "OPSCalendar":
                    reply[name] = {"Mask": 1 << 24}
                elif name == "OPFileQuery":
                    query = data[name]
                    records = []
                    for minute in [0, 1]:
                        begin = f"2026-10-25 00:0{minute}:00"
                        end = f"2026-10-25 00:0{minute}:03"
                        if query["BeginTime"] <= begin <= query["EndTime"]:
                            records.append({"FileName": f"/synthetic/{minute}.h264", "BeginTime": begin, "EndTime": end, "FileLength": 100, "DiskNo": 0, "SerialNo": minute})
                    reply[name] = records
                    reply["Ret"] = (111 if query["EndTime"].startswith("2026-10-25") else 110) if records else 119
                elif name == "OPPlayBack":
                    action = data[name]["Action"]
                    file_name = data[name].get("Parameter", {}).get("FileName", "")
                    started, stopped = state.transfer(file_name, renew=action != "DownloadStop")
                    if action == "Claim":
                        # Start on the other socket may arrive before this Claim.
                        # Never clear an already received Start notification.
                        if not started.wait(10):
                            return
                        self.request.sendall(frame(1, sequence, 1425, json.dumps(reply).encode() + b"\n\0"))
                        raw = state.raw
                        slow = "/1." in data[name].get("Parameter", {}).get("FileName", "")
                        for offset in range(0, len(raw), 127):
                            if stopped.is_set():
                                return
                            self.request.sendall(frame(1, sequence, 1426, raw[offset:offset + 127]))
                            if slow:
                                time.sleep(0.01)
                        self.request.sendall(frame(1, sequence, 1423))
                        continue
                    if action == "DownloadStart":
                        started.set()
                    elif action == "DownloadStop":
                        stopped.set()
                elif message != 1006:
                    reply["Ret"] = 605
                self.request.sendall(frame(1, sequence, message + 1, json.dumps(reply).encode() + b"\n\0"))
        except (EOFError, OSError, ValueError, KeyError, struct.error):
            pass


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("--invalid-media", action="store_true")
    args = parser.parse_args()
    server = Server(("127.0.0.1", 0), Peer)
    raw = bytearray(args.raw.read_bytes())
    if args.invalid_media:
        raw[0] = 255
    server.state = State(bytes(raw))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"controlPort": server.server_address[1]}), flush=True)
    stopped = threading.Event()
    for sig in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(sig, lambda *_: stopped.set())
    stopped.wait()
    for started, stopped in server.state.transfers.values():
        stopped.set(); started.set()
    server.shutdown(); server.server_close()


if __name__ == "__main__":
    main()
