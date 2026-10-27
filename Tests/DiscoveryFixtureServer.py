"""Loopback WS-Discovery peer: checks a real anonymous UDP Probe and replies twice."""
import json
import socket
import xml.etree.ElementTree as ET

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('127.0.0.1', 0))
print(json.dumps({'port': sock.getsockname()[1]}), flush=True)
while True:
    payload, sender = sock.recvfrom(32768)
    assert b'Username' not in payload and b'Password' not in payload
    envelope = ET.fromstring(payload)
    ns = {'a': 'http://schemas.xmlsoap.org/ws/2004/08/addressing',
          'd': 'http://schemas.xmlsoap.org/ws/2005/04/discovery'}
    message_id = envelope.find('.//a:MessageID', ns).text
    assert envelope.find('.//d:Probe', ns) is not None
    reply = f'''<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="{ns['a']}" xmlns:d="{ns['d']}"><s:Header><a:RelatesTo>{message_id}</a:RelatesTo></s:Header><s:Body><d:ProbeMatches><d:ProbeMatch><d:Types>dn:NetworkVideoTransmitter</d:Types><d:Scopes>onvif://www.onvif.org/name/Fixture</d:Scopes><d:XAddrs>http://127.0.0.1:8080/custom/device</d:XAddrs></d:ProbeMatch></d:ProbeMatches></s:Body></s:Envelope>'''.encode()
    sock.sendto(reply, sender)
    sock.sendto(reply, sender)
