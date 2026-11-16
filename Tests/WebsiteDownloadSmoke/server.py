"""Local deterministic transfer fixtures. Never contacts a manga website."""
import http.server
import json
import sys
import threading
import time

lock = threading.Lock()
active = peak = 0

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global active, peak
        if self.path == '/stats':
            with lock:
                body = json.dumps({'peak': peak, 'active': active}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with lock:
            active += 1
            peak = max(active, peak)
        try:
            if self.path == '/oversize':
                self.send_response(200)
                self.send_header('Content-Length', str(41 * 1024 * 1024))
                self.end_headers()
                for _ in range(41):
                    self.wfile.write(b'x' * 1024 * 1024)
                    self.wfile.flush()
                    time.sleep(.02)
                return
            index = int(self.path.rsplit('/', 1)[-1])
            time.sleep(.15 * (3 - index % 3))  # deliberately complete out of order
            body = bytes([index]) * (256 * 1024)
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with lock:
                active -= 1

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as output:
    output.write(str(server.server_port))
server.serve_forever()
