"""Local Codex JSONL transport. No credentials are read or copied."""
import hashlib
import json
import math
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time
import uuid


def credential_stamp():
    root = Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))
    result = []
    for name in ('auth.json', 'config.toml'):
        try:
            s = (root / name).stat()
            result.append((s.st_mtime_ns, s.st_size, s.st_ino))
        except OSError:
            result.append(None)
    return tuple(result)


def parse_snapshot(payload):
    buckets = payload.get('rateLimitsByLimitId')
    bucket = buckets.get('codex') if isinstance(buckets, dict) else payload.get('rateLimits')
    if not isinstance(bucket, dict):
        raise ValueError('当前账号未返回 Codex 额度')
    windows = []
    for key in ('primary', 'secondary'):
        raw = bucket.get(key)
        if not raw:
            continue
        used, duration, reset = (float(raw[k]) for k in ('usedPercent', 'windowDurationMins', 'resetsAt'))
        if not all(math.isfinite(n) for n in (used, duration, reset)) or duration <= 0:
            raise ValueError('额度格式无效')
        windows.append(dict(remaining=max(0, min(100, 100-used)), duration=int(duration), reset=reset))
    if not windows:
        raise ValueError('当前账号未返回额度窗口')
    credits = (payload.get('rateLimitResetCredits') or {}).get('availableCount')
    return dict(windows=windows, account=payload.get('accountId'), credits=credits,
                plan=bucket.get('planType') or '', updated=time.time())


def discover_codex():
    explicit = os.environ.get('QUOTANOOK_CODEX')
    if explicit and Path(explicit).is_file():
        return explicit
    executable = shutil.which('codex.exe') or shutil.which('codex')
    if executable and Path(executable).suffix.lower() not in ('.cmd', '.bat'):
        return executable
    # npm's Windows wrapper is a shell script; launch its native vendor binary directly.
    roots = [Path(os.environ.get('APPDATA', '')) / 'npm/node_modules/@openai',
             Path(os.environ.get('LOCALAPPDATA', '')) / 'Programs/Codex']
    for root in roots:
        if root.exists():
            candidates = list(root.glob('**/codex.exe'))
            if candidates:
                return str(candidates[0])
    raise FileNotFoundError('请安装 Codex CLI，或设置 QUOTANOOK_CODEX 为 codex.exe 路径')


class PendingKeys:
    def __init__(self, path):
        self.path = Path(path)

    def _read(self):
        if not self.path.exists():
            return {}
        # Never replace an unreadable pending key: a retry could consume twice.
        return json.loads(self.path.read_text(encoding='utf-8'))

    def _write(self, data):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix('.tmp')
        temp.write_text(json.dumps(data), encoding='utf-8')
        temp.replace(self.path)

    def key(self, account):
        digest = hashlib.sha256(account.encode()).hexdigest()
        data = self._read()
        if digest not in data:
            data[digest] = str(uuid.uuid4())
            self._write(data)
        return data[digest]

    def resolve(self, account):
        data = self._read()
        data.pop(hashlib.sha256(account.encode()).hexdigest(), None)
        self._write(data)


class Session:
    def __init__(self, command):
        self.stamp = credential_stamp()
        self.inbox = queue.Queue()
        self.serial = 0
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding='utf-8', bufsize=1,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        threading.Thread(target=self._reader, daemon=True).start()
        self.request('initialize', {'clientInfo': {'name': 'quotanook', 'title': 'QuotaNook', 'version': '0.1.0'}})
        self.send({'method': 'initialized', 'params': {}})

    def _reader(self):
        try:
            for line in self.process.stdout:
                try:
                    self.inbox.put(json.loads(line))
                except ValueError:
                    continue
        finally:
            self.inbox.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()

    def request(self, method, params=None, timeout=20):
        self.serial += 1
        request_id = self.serial
        self.send({'id': request_id, 'method': method, 'params': params or {}})
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('读取超时，请重试')
            try:
                message = self.inbox.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError('读取超时，请重试') from None
            if message is None:
                raise ConnectionError('Codex 数据连接已断开')
            if message.get('id') != request_id:
                continue
            if 'error' in message:
                raise RuntimeError(str(message['error'].get('message', 'Codex 返回错误')))
            if credential_stamp() != self.stamp:
                raise RuntimeError('账号已变化，正在重新连接')
            return message.get('result', {})

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        for pipe in (self.process.stdin, self.process.stdout):
            if pipe:
                pipe.close()
