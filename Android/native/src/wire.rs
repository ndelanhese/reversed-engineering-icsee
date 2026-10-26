use crate::core::{self, Result};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    net::{Shutdown, TcpStream, ToSocketAddrs},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
pub const MAX_PAYLOAD: usize = 2 * 1024 * 1024;
#[derive(Debug)]
pub struct Packet {
    pub session: u32,
    pub sequence: u32,
    pub message: u16,
    pub fragment: u8,
    pub end: u8,
    pub payload: Vec<u8>,
}
impl Packet {
    pub fn encode(&self) -> Result<Vec<u8>> {
        if self.payload.len() > MAX_PAYLOAD {
            return Err("response_too_large".into());
        }
        let mut b = Vec::with_capacity(20 + self.payload.len());
        b.extend([255, 0, 0, 0]);
        b.extend(self.session.to_le_bytes());
        b.extend(self.sequence.to_le_bytes());
        b.extend([self.fragment, self.end]);
        b.extend(self.message.to_le_bytes());
        b.extend((self.payload.len() as u32).to_le_bytes());
        b.extend(&self.payload);
        Ok(b)
    }
    pub fn read(r: &mut impl Read) -> Result<Self> {
        let mut h = [0_u8; 20];
        r.read_exact(&mut h).map_err(|_| "incomplete_transfer")?;
        if h[0] != 255 || h[1] > 1 || h[2] != 0 || h[3] != 0 {
            return Err("invalid_response".into());
        }
        let u32at = |i| u32::from_le_bytes(h[i..i + 4].try_into().unwrap());
        let n = u32at(16) as usize;
        if n > MAX_PAYLOAD {
            return Err("response_too_large".into());
        }
        let mut payload = vec![0; n];
        r.read_exact(&mut payload)
            .map_err(|_| "incomplete_transfer")?;
        Ok(Self {
            session: u32at(4),
            sequence: u32at(8),
            message: u16::from_le_bytes([h[14], h[15]]),
            fragment: h[12],
            end: h[13],
            payload,
        })
    }
    pub fn check(&self, message: u16, sequence: u32, session: u32) -> Result<()> {
        if self.message != message + 1
            || self.sequence & !1 != sequence & !1
            || self.session != session
            || self.fragment > 1
            || self.end != 0
        {
            return Err("invalid_response".into());
        }
        Ok(())
    }
}
pub fn check_cancel(c: &AtomicBool) -> Result<()> {
    if c.load(Ordering::Relaxed) {
        Err("cancelled".into())
    } else {
        Ok(())
    }
}
struct TimedRead<'a> {
    stream: &'a mut TcpStream,
    cancel: &'a AtomicBool,
    deadline: Instant,
}
impl Read for TimedRead<'_> {
    fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.cancel.load(Ordering::Relaxed) {
                return Err(io::ErrorKind::ConnectionAborted.into());
            }
            if Instant::now() >= self.deadline {
                return Err(io::ErrorKind::TimedOut.into());
            }
            match self.stream.read(b) {
                Err(e)
                    if [io::ErrorKind::TimedOut, io::ErrorKind::WouldBlock].contains(&e.kind()) =>
                {
                    continue
                }
                result => return result,
            }
        }
    }
}
pub fn unsigned(v: &Value) -> Result<u64> {
    if let Some(n) = v.as_u64() {
        return Ok(n);
    }
    let s = v.as_str().ok_or("invalid_response")?;
    if let Some(s) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u64::from_str_radix(s, 16).map_err(|_| "invalid_response".into())
    } else {
        s.parse().map_err(|_| "invalid_response".into())
    }
}
pub fn check_return(v: &Value, search: bool) -> Result<u64> {
    let n = unsigned(&v["Ret"])?;
    match n {
        100 | 150 => Ok(n),
        109 | 110 | 111 | 119 if search => Ok(n),
        104 | 105 | 106 | 202..=207 => Err("authentication".into()),
        103 | 107 | 213 => Err("forbidden".into()),
        102 | 210 | 211 | 502 | 605 | 607 => Err("unsupported".into()),
        108 => Err("timeout".into()),
        _ => Err("rejected".into()),
    }
}
pub struct Session {
    stream: TcpStream,
    pub session: u32,
    pub sequence: u32,
    cancel: Arc<AtomicBool>,
    early: VecDeque<Packet>,
    early_bytes: usize,
    last_alive: Instant,
}
impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}
impl Session {
    pub fn connect(v: &Value, session: u32, cancel: Arc<AtomicBool>) -> Result<Self> {
        check_cancel(&cancel)?;
        let host = core::host(v)?;
        let port = core::port(v, "controlPort", 34567)?;
        let addresses = (host, port).to_socket_addrs().map_err(|_| "unreachable")?;
        let mut stream = None;
        let deadline = Instant::now() + Duration::from_secs(4);
        for address in addresses.take(8) {
            check_cancel(&cancel)?;
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            if let Ok(s) = TcpStream::connect_timeout(&address, remaining) {
                stream = Some(s);
                break;
            }
        }
        let stream = stream.ok_or("unreachable")?;
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .map_err(|_| "unreachable")?;
        stream
            .set_write_timeout(Some(Duration::from_secs(2)))
            .map_err(|_| "unreachable")?;
        Ok(Self {
            stream,
            session,
            sequence: 0,
            cancel,
            early: VecDeque::new(),
            early_bytes: 0,
            last_alive: Instant::now(),
        })
    }
    pub fn login(v: &Value, cancel: Arc<AtomicBool>) -> Result<Self> {
        let mut s = Self::connect(v, 0, cancel)?;
        let reply=s.exchange(1000,json!({"EncryptType":"MD5","LoginType":"DVRIP-Web","UserName":core::text(v,"username")?,"PassWord":core::sofia(core::text(v,"password")?)}),false)?;
        check_return(&reply, false)?;
        if s.session == 0 || unsigned(&reply["SessionID"])? != u64::from(s.session) {
            return Err("invalid_response".into());
        }
        Ok(s)
    }
    pub fn send(&mut self, message: u16, mut body: Value) -> Result<u32> {
        check_cancel(&self.cancel)?;
        if message != 1000 {
            body["SessionID"] = json!(format!("0x{:08x}", self.session));
        }
        let mut payload = serde_json::to_vec(&body).map_err(|_| "invalid_input")?;
        payload.extend([10, 0]);
        let seq = self.sequence;
        self.sequence = self.sequence.wrapping_add(2);
        let bytes = Packet {
            session: self.session,
            sequence: seq,
            message,
            fragment: 0,
            end: 0,
            payload,
        }
        .encode()?;
        self.stream.write_all(&bytes).map_err(|_| "disconnected")?;
        Ok(seq)
    }
    pub fn next(&mut self, seconds: u64) -> Result<Packet> {
        check_cancel(&self.cancel)?;
        let p = Packet::read(&mut TimedRead {
            stream: &mut self.stream,
            cancel: &self.cancel,
            deadline: Instant::now() + Duration::from_secs(seconds),
        });
        check_cancel(&self.cancel)?;
        p
    }
    pub fn reply(&mut self, message: u16, seq: u32, allow_media: bool) -> Result<Value> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if Instant::now() >= deadline {
                return Err("timeout".into());
            }
            let p = self.next(
                deadline
                    .saturating_duration_since(Instant::now())
                    .as_secs()
                    .max(1),
            )?;
            if allow_media && [1426, 1423].contains(&p.message) {
                if p.session != self.session
                    || self.early.len() >= 1024
                    || self.early_bytes + p.payload.len() > 8 * 1024 * 1024
                {
                    return Err("invalid_response".into());
                }
                self.early_bytes += p.payload.len();
                self.early.push_back(p);
                continue;
            }
            p.check(
                message,
                seq,
                if message == 1000 {
                    p.session
                } else {
                    self.session
                },
            )?;
            let bytes = p.payload.trim_ascii_end();
            let bytes = bytes.strip_suffix(&[0]).unwrap_or(bytes).trim_ascii_end();
            let v: Value = serde_json::from_slice(bytes).map_err(|_| "invalid_response")?;
            if !v.is_object() {
                return Err("invalid_response".into());
            }
            if let Some(token) = v.get("SessionID") {
                if unsigned(token)? != u64::from(p.session) {
                    return Err("invalid_response".into());
                }
            }
            if message == 1000 {
                self.session = p.session;
            }
            return Ok(v);
        }
    }
    pub fn exchange(&mut self, message: u16, body: Value, allow_media: bool) -> Result<Value> {
        let seq = self.send(message, body)?;
        self.reply(message, seq, allow_media)
    }
    pub fn keep_alive(&mut self) -> Result<()> {
        if self.last_alive.elapsed() > Duration::from_secs(10) {
            let v = self.exchange(1006, json!({"Name":"KeepAlive"}), false)?;
            check_return(&v, false)?;
            self.last_alive = Instant::now();
        }
        Ok(())
    }
    pub fn media(&mut self) -> Result<Packet> {
        let p = if let Some(p) = self.early.pop_front() {
            self.early_bytes -= p.payload.len();
            p
        } else {
            self.next(15)?
        };
        if p.session != self.session || ![1426, 1423].contains(&p.message) {
            return Err("invalid_response".into());
        }
        Ok(p)
    }
    pub fn has_buffered_media(&self) -> bool {
        !self.early.is_empty()
    }
    pub fn cleanup(&mut self, body: Value) {
        let old = self.cancel.clone();
        self.cancel = Arc::new(AtomicBool::new(false));
        let _ = self.exchange(1420, body, false);
        self.cancel = old;
    }
    pub fn read_setting(&mut self, name: &str, capability: bool) -> Result<Value> {
        let v = self.exchange(
            if capability {
                1360
            } else if name == "SystemInfo" {
                1020
            } else {
                1042
            },
            json!({"Name":name}),
            false,
        )?;
        check_return(&v, false)?;
        v.get(name).cloned().ok_or("unsupported".into())
    }
}
