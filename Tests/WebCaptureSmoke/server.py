"""Local fixtures, including a stalled image request. Never accesses the Internet."""
import base64
import functools
import http.server
import sys
import time


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/challenge':
            data = b'''<html><head><title>Verification fixture</title></head><body>Complete verification
<script>
window.verificationFrames = [];
window.addEventListener('message', event => {
    if (event.data === 'blob-ready' || event.data === 'data-ready') {
        window.verificationFrames.push(event.data);
    }
});
for (const kind of ['blob', 'data']) {
    const html = '<script>parent.postMessage("' + kind + '-ready", "*")<' + '/script>';
    const frame = document.createElement('iframe');
    frame.src = kind === 'blob'
        ? URL.createObjectURL(new Blob([html], {type: 'text/html'}))
        : 'data:text/html,' + encodeURIComponent(html);
    document.body.append(frame);
}
</script></body></html>'''
            self.send_response(403)
            self.send_header('Content-Type', 'text/html')
            self.send_header('cf-mitigated', 'challenge')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith('/stalled.png'):
            time.sleep(45)
            data = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aG1sAAAAASUVORK5CYII=')
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'image/png')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            super().do_GET()


server = http.server.ThreadingHTTPServer(
    ('127.0.0.1', 0), functools.partial(Handler, directory=sys.argv[1]))
with open(sys.argv[2], 'w') as port_file:
    port_file.write(str(server.server_port))
server.serve_forever()
