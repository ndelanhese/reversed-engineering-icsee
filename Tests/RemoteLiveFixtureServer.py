"""Local, synthetic P2P peer. No real camera, credentials or vendor network."""
import json
import select
import signal
import socket
import struct
import subprocess
import sys
import time


def endpoint():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', 0))
    return sock


def le(value):
    return struct.pack('<I', value)


def padded(value, count):
    return value.encode('ascii').ljust(count, b'\0')


def outer(body):
    return bytes.fromhex('1220d3070000') + struct.pack('<H', len(body)) + bytes(4) + body


def dvrip(message, sequence, payload, session=42):
    body = json.dumps(payload, separators=(',', ':')).encode() + b'\n\0' if isinstance(payload, dict) else payload
    return struct.pack('<BB2xII2xHI', 255, 0, session, sequence, message, len(body)) + body


def run(binary, mode):
    sockets = [endpoint() for _ in range(5)]
    bootstrap, lookup, nat, direct, proxy = sockets
    ports = [str(item.getsockname()[1]) for item in sockets]
    process = subprocess.Popen([binary, mode, *ports], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 22
    accepted = False
    peer_address = None
    peer_socket = None
    incoming_sequence = 0
    seen = set()
    events = set()
    video_at = 0
    dropped_keepalives = 0

    def send_message(code, payload, send=True, session=42):
        nonlocal incoming_sequence
        frame = dvrip(code, 2 if code == 1414 else incoming_sequence, payload, session=session)
        body = b'XMIP' + le(incoming_sequence) + bytes([1, 14, 0, 0]) + frame
        packet = outer(body)
        if send:
            peer_socket.sendto(packet, peer_address)
        incoming_sequence += 1
        return packet

    try:
        while time.monotonic() < deadline:
            now = time.monotonic()
            if accepted and 'start' in events and now >= video_at:
                key = bytes([0, 0, 1, 0xfc, 3, 15, 80, 45, 0, 0, 0, 0, 3, 0, 0, 0, 0xaa, 0xbb, 0xcc])
                if 'reordered' not in events:
                    first = send_message(1412, key, send=False)
                    second = send_message(1412, key, send=False)
                    peer_socket.sendto(second, peer_address)
                    peer_socket.sendto(first, peer_address)
                    events.add('reordered')
                else:
                    send_message(1412, key)
                video_at = now + 0.2
            readable, _, _ = select.select(sockets, [], [], 0.05)
            for sock in readable:
                packet, address = sock.recvfrom(65535)
                if sock is bootstrap:
                    sock.sendto(bytes.fromhex('1420f505') + padded('1.1.1.1', 20), address)
                elif sock is lookup:
                    response = bytearray(140)
                    response[:8] = bytes.fromhex('152001b001000000')
                    response[108:128] = padded('2.2.2.2', 20)
                    response[128:132] = le(8765)
                    sock.sendto(response, address)
                elif sock is nat:
                    if packet.startswith(bytes.fromhex('1220ea03')):
                        sock.sendto(bytes.fromhex('1220eb03') + bytes(16), address)
                    elif packet.startswith(bytes.fromhex('1220e803')):
                        sock.sendto(bytes.fromhex('1220e903') + padded('9.9.9.9', 16) + le(address[1]), address)
                    elif packet.startswith(bytes.fromhex('1220ec03')):
                        sock.sendto(bytes.fromhex('1220ed03') + packet[4:8] + le(1), address)
                        incoming = bytearray(360)
                        incoming[:4] = bytes.fromhex('1220ec03')
                        incoming[4:8] = le(17)
                        incoming[208:224] = padded('3.3.3.3', 16)
                        incoming[224:226] = struct.pack('<H', 4000)
                        incoming[328:332] = packet[4:8]
                        if mode != 'direct':
                            incoming[332:348] = padded('8.8.8.8', 16)
                            incoming[348:352] = le(4001)
                        sock.sendto(incoming, address)
                elif sock in (direct, proxy):
                    if sock is direct and mode != 'direct':
                        continue
                    if packet.startswith(bytes.fromhex('1220b90b')):
                        events.add('proxy')
                        sock.sendto(bytes.fromhex('1220ba0b') + bytes(4), address)
                    elif packet.startswith(bytes.fromhex('1220d007')):
                        peer_socket, peer_address = sock, address
                        greeting = bytes.fromhex('1220d007') + le(17) + padded('1234567890abcdef', 100) + bytes(4)
                        sock.sendto(greeting, address)
                    elif packet.startswith(bytes.fromhex('1220d107')):
                        peer_socket, peer_address = sock, address
                        if mode != 'cancel':
                            accepted = True
                            sock.sendto(bytes.fromhex('1220d107') + le(17) + padded('1234567890abcdef', 100) + bytes(4), address)
                    elif packet.startswith(bytes.fromhex('1220d307')) and len(packet) >= 44 and packet[12:16] == b'XMIP':
                        flags = packet[21]
                        if flags & 3 != 2:
                            continue
                        sequence = struct.unpack_from('<I', packet, 16)[0]
                        frame = packet[24:]
                        code = struct.unpack_from('<H', frame, 14)[0]
                        body = json.loads(frame[20:].rstrip(b'\n\0')) if code == 1410 else None
                        action = body['OPMonitor']['Action'] if body else None
                        if mode == 'cancel_start_lost' and action == 'Start':
                            if 'start_lost' in events:
                                events.add('start_retransmitted')
                            else:
                                events.add('start_lost')
                                process.send_signal(signal.SIGUSR1)
                            continue
                        if mode == 'cancel_keepalive_lost' and code == 1006 and dropped_keepalives < 2:
                            dropped_keepalives += 1
                            events.add('keepalive_lost')
                            if dropped_keepalives == 1:
                                process.send_signal(signal.SIGUSR1)
                            continue
                        if mode == 'cancel_keepalive_lost' and action == 'Stop' and 'keepalive' not in events:
                            continue
                        # Lose the first login ACK: the client must retry the same sequence.
                        first = sequence not in seen
                        withhold = first and ((mode == 'cancel_start' and action == 'Start') or (mode == 'cancel_keepalive' and code == 1006))
                        if not withhold and not (code == 1000 and first):
                            sock.sendto(outer(b'XMIP' + le(sequence) + bytes([1, 1, 0, 0])), address)
                        if not first:
                            events.add('retry')
                            continue
                        seen.add(sequence)
                        if code == 1000:
                            events.add('login')
                            send_message(1001, {'Ret': 203 if mode == 'bad_auth' else 100, 'SessionID': '0x0000002A', 'AliveInterval': 2})
                        elif code == 1413:
                            events.add('claim')
                            send_message(1414, {'Ret': 100}, session=43 if mode == 'bad_session' else 42)
                        elif code == 1410:
                            events.add(action.lower())
                        elif code == 1006:
                            events.add('keepalive')
                            send_message(1007, {'Ret': 100})
                        if withhold:
                            process.send_signal(signal.SIGUSR1)
            if process.poll() is not None:
                # Allow the final UDP Stop datagram to be read before checking.
                if mode in ('cancel', 'bad_session', 'bad_auth', 'cancel_start_lost') or 'stop' in events:
                    break
        stdout, stderr = process.communicate(timeout=2)
        if process.returncode != 0:
            raise RuntimeError('fixture client failed: ' + str(process.returncode) + ' events=' + str(sorted(events)) + ' ' + stdout[-500:] + stderr[-500:])
        if mode == 'cancel':
            if 'login' in events:
                raise RuntimeError('login sent after cancellation')
        elif mode == 'bad_session':
            if 'claim' not in events or 'start' in events:
                raise RuntimeError('foreign claim response was accepted')
        elif mode == 'bad_auth':
            if 'login' not in events or 'claim' in events:
                raise RuntimeError('rejected login was accepted')
        elif mode == 'cancel_start_lost':
            if 'start_lost' not in events or 'start_retransmitted' in events:
                raise RuntimeError('lost Start was sent again after cancellation')
        else:
            required = {'login', 'retry', 'claim', 'start', 'stop'}
            if mode != 'cancel_start':
                required |= {'keepalive', 'reordered'}
            if mode == 'cancel_keepalive_lost':
                required.add('keepalive_lost')
            if not required.issubset(events) or (mode == 'relay' and 'proxy' not in events):
                raise RuntimeError('missing fixture events: ' + str(sorted(required - events)))
        print(stdout.strip())
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for sock in sockets:
            sock.close()


if __name__ == '__main__':
    for scenario in (sys.argv[2:] or ('direct', 'relay', 'cancel', 'cancel_start', 'cancel_keepalive', 'cancel_start_lost', 'cancel_keepalive_lost', 'bad_session', 'bad_auth')):
        run(sys.argv[1], scenario)
