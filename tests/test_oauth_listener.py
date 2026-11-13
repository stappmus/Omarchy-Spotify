import pathlib
import socket
import subprocess
import sys
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/oauth-listener.py'


class ListenerTests(unittest.TestCase):
    def test_occupied_port_never_announces_ready(self):
        with socket.socket() as held:
            held.bind(('127.0.0.1', 0))
            held.listen()
            result = subprocess.run([sys.executable, str(SCRIPT), str(held.getsockname()[1])], capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 21)
            self.assertEqual(result.stdout, b'')

    def test_ready_socket_accepts_immediate_callback(self):
        # Reserve a candidate; startup explicitly fails if another process wins.
        with socket.socket() as candidate:
            candidate.bind(('127.0.0.1', 0))
            port = candidate.getsockname()[1]
        proc = subprocess.Popen([sys.executable, str(SCRIPT), str(port)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        try:
            self.assertEqual(proc.stdout.readline(), b'READY\n')
            with socket.create_connection(('127.0.0.1', port), timeout=3) as client:
                client.sendall(b'GET /login?code=test&state=test HTTP/1.1\r\nHost: localhost\r\n\r\n')
                self.assertEqual(proc.stdout.readline(), b'GET /login?code=test&state=test HTTP/1.1\n')
                response = b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK'
                proc.stdin.write(response)
                proc.stdin.flush()
                self.assertEqual(client.recv(8192), response)
            self.assertEqual(proc.wait(timeout=3), 0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdin.close()
            proc.stdout.close()


if __name__ == '__main__':
    unittest.main()
