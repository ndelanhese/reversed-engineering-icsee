#!/usr/bin/env python3
"""Synthetic loopback-only ONVIF/DVRIP peer; never records credentials or bodies."""
import argparse
import collections
import copy
import http.server
import json
import signal
import socketserver
import struct
import threading
import time
import xml.etree.ElementTree as ET


class State:
    def __init__(self, array_camera_param=False):
        self.lock = threading.RLock()
        self.order = []
        self.counts = collections.Counter()
        self.brightness = 42
        self.imaging_extension_preserved = True
        param = {"Brightness": 42, "Unknown": {"Keep": "synthetic-extension", "Enabled": True}, "Channels": [1, 2]}
        self.config = {"Camera.Param": [param] if array_camera_param else param,
                       "Record": [{"Enable": True, "Mode": "synthetic", "Unknown": 17}],
                       "SystemFunction": {"PTZ": True, "Imaging": True},
                       "SystemInfo": {"DeviceType": "Synthetic localhost fixture", "Synthetic": True}}
        self.connections = 0
        self.reboot_at = None
        self.reboot_close_delays = []

    def command(self, name):
        with self.lock:
            self.order.append(name)
            self.counts[name] += 1

    def stats(self):
        with self.lock:
            return {"order": list(self.order), "counts": dict(self.counts), "brightness": self.brightness,
                    "config": copy.deepcopy(self.config), "imagingExtensionPreserved": self.imaging_extension_preserved,
                    "openConnections": self.connections, "rebootCloseDelays": list(self.reboot_close_delays)}


def local_name(element):
    return element.tag.rsplit("}", 1)[-1]


def first(root, name):
    return next((node for node in root.iter() if local_name(node) == name), None)


class SOAPHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/__stats":
            self.send_error(404)
            return
        self.reply(json.dumps(self.server.state.stats()).encode(), "application/json")

    def reply(self, body, content_type="application/soap+xml; charset=utf-8"):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if not 0 < length <= 65536:
            self.send_error(400)
            return
        try:
            root = ET.fromstring(self.rfile.read(length))
            body = first(root, "Body")
            action = local_name(body[0])
            namespace = body[0].tag[1:].split("}", 1)[0]
        except (ET.ParseError, TypeError, IndexError):
            self.send_error(400)
            return
        state = self.server.state
        state.command("ONVIF:" + action)
        port = self.server.server_address[1]
        value = ""
        if action == "GetServices":
            value = "".join(f"<Service><Namespace>http://www.onvif.org/{version}/{kind}/wsdl</Namespace><XAddr>http://127.0.0.1:{port}/onvif/{kind}</XAddr></Service>" for version, kind in [("ver10", "media"), ("ver20", "ptz"), ("ver20", "imaging")])
        elif action == "GetProfiles":
            value = '<Profiles token="synthetic-main"><Name>Synthetic main</Name><VideoSourceConfiguration><SourceToken>synthetic-source</SourceToken></VideoSourceConfiguration><PTZConfiguration token="synthetic-ptz"/></Profiles>'
        elif action == "GetConfigurationOptions":
            value = '<PTZConfigurationOptions><Spaces><ContinuousPanTiltVelocitySpace><URI>urn:synthetic:pan-tilt</URI><XRange><Min>-1</Min><Max>1</Max></XRange><YRange><Min>-1</Min><Max>1</Max></YRange></ContinuousPanTiltVelocitySpace><ContinuousZoomVelocitySpace><URI>urn:synthetic:zoom</URI><XRange><Min>-1</Min><Max>1</Max></XRange></ContinuousZoomVelocitySpace></Spaces><PTZTimeout><Min>PT0.1S</Min><Max>PT1S</Max></PTZTimeout></PTZConfigurationOptions>'
        elif action == "GetOptions":
            value = '<ImagingOptions><Brightness><Min>0</Min><Max>100</Max></Brightness></ImagingOptions>'
        elif action == "GetImagingSettings":
            with state.lock:
                value = f'<ImagingSettings><Brightness>{state.brightness}</Brightness><Extension><SyntheticKeep>preserve-me</SyntheticKeep></Extension></ImagingSettings>'
        elif action == "SetImagingSettings":
            brightness, extension = first(root, "Brightness"), first(root, "SyntheticKeep")
            with state.lock:
                state.brightness = float(brightness.text)
                state.imaging_extension_preserved = extension is not None and extension.text == "preserve-me"
        elif action == "ContinuousMove":
            time.sleep(0.35)  # Keep a real request pending when close/Quit cancels it.
        elif action == "GetPresets":
            value = '<Preset token="synthetic-preset"><Name>Synthetic home</Name></Preset>'
        elif action == "SetPreset":
            value = '<PresetToken>synthetic-preset</PresetToken>'
        elif action == "GotoPreset":
            time.sleep(0.35)
        elif action == "GetStatus":
            value = '<PTZStatus><MoveStatus><PanTilt>MOVING</PanTilt><Zoom>MOVING</Zoom></MoveStatus></PTZStatus>'
        elif action != "Stop":
            self.send_error(400)
            return
        response = f'<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><{action}Response xmlns="{namespace}">{value}</{action}Response></s:Body></s:Envelope>'
        self.reply(response.encode())


class DVRIPHandler(socketserver.BaseRequestHandler):
    def read_exact(self, length):
        result = b""
        while len(result) < length:
            chunk = self.request.recv(length - len(result))
            if not chunk:
                raise EOFError
            result += chunk
        return result

    def handle(self):
        state = self.server.state
        reboot_at = None
        with state.lock:
            state.connections += 1
        try:
            while True:
                header = self.read_exact(20)
                magic, version, reserved, session, sequence, fragments, message, length = struct.unpack("<BBHIIHHI", header)
                if magic != 255 or version > 1 or reserved or fragments or length > 65536:
                    return
                payload = json.loads(self.read_exact(length).rstrip(b"\x00\r\n"))
                # Never retain login fields or raw SOAP/JSON payloads.
                name = "Login" if message == 1000 else payload.get("Name", "Unknown")
                state.command(f"DVRIP:{message}:{name}")
                response = {"Ret": 100, "SessionID": "0x00000001"}
                if message == 1000:
                    response["AliveInterval"] = 3600
                elif session != 1:
                    response["Ret"] = 106
                elif message == 1006:
                    pass
                elif message in (1042, 1360, 1020):
                    with state.lock:
                        if name in state.config:
                            response[name] = copy.deepcopy(state.config[name])
                        else:
                            response["Ret"] = 605
                elif message == 1040 and name in ("Camera.Param", "Record"):
                    with state.lock:
                        state.config[name] = copy.deepcopy(payload[name])
                elif message == 1450 and payload.get("OPMachine", {}).get("Action") == "Reboot":
                    reboot_at = time.monotonic()
                else:
                    response["Ret"] = 605
                encoded = json.dumps(response, separators=(",", ":")).encode() + b"\n\x00"
                self.request.sendall(struct.pack("<BBHIIHHI", 255, 0, 0, 1, sequence, 0, message + 1, len(encoded)) + encoded)
        except (EOFError, OSError, ValueError, KeyError, struct.error):
            pass
        finally:
            with state.lock:
                state.connections -= 1
                if reboot_at is not None:
                    state.reboot_close_delays.append(time.monotonic() - reboot_at)


class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--array-camera-param", action="store_true")
    args = parser.parse_args()
    state = State(args.array_camera_param)
    http_peer = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SOAPHandler)
    tcp = TCPServer(("127.0.0.1", 0), DVRIPHandler)
    http_peer.state = tcp.state = state
    for server in (http_peer, tcp):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"onvifPort": http_peer.server_address[1], "controlPort": tcp.server_address[1]}), flush=True)
    stopped = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopped.set())
    stopped.wait()
    for server in (http_peer, tcp):
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
