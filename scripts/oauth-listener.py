#!/usr/bin/env python3
"""Own a loopback OAuth socket before signalling readiness to the QML client."""
import errno
import os
import select
import socket
import sys
import time


def serve(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        try:
            listener.bind(('127.0.0.1', port))
            listener.listen(1)
        except OSError as error:
            return 21 if error.errno == errno.EADDRINUSE else 22
        print('READY', flush=True)
        listener.settimeout(180)
        with listener.accept()[0] as client:
            client.settimeout(5)
            data = b''
            while b'\r\n' not in data:
                chunk = client.recv(1024)
                if not chunk or len(data) + len(chunk) > 8192:
                    return 23
                data += chunk
            print(data.split(b'\r\n', 1)[0].decode('ascii', errors='replace'), flush=True)
            # QML writes a complete HTTP response. Read its headers and body,
            # rather than relying on a pipe write arriving as a single read.
            response = b''
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([sys.stdin.buffer], [], [], max(0, deadline-time.monotonic()))[0]:
                    return 23
                chunk = os.read(sys.stdin.fileno(), 8192)
                if not chunk:
                    return 23
                response += chunk
                if len(response) > 65536:
                    return 23
                if b'\r\n\r\n' in response:
                    head, body = response.split(b'\r\n\r\n', 1)
                    lengths = [line.split(b':', 1)[1].strip() for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:')]
                    if lengths and len(body) >= int(lengths[0]):
                        client.sendall(response)
                        return 0
            return 23


if __name__ == '__main__':
    try:
        raise SystemExit(serve(int(sys.argv[1])))
    except (OSError, ValueError, IndexError):
        raise SystemExit(23)
