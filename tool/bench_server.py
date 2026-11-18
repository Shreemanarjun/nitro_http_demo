# Local keep-alive HTTP/1.1 server for the benchmark, so results measure the
# client, not the internet. Run: python3 tool/bench_server.py  (port 8765)
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BODIES = {'/small': b'x' * 1024, '/large': b'x' * (1024 * 1024)}


class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        body = BODIES.get(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # the app posts its results here (release has no logs)
        body = self.rfile.read(int(self.headers['Content-Length']))
        print(body.decode(), flush=True)
        self.send_response(204)
        self.send_header('Content-Length', '0')
        self.end_headers()

    def log_message(self, *a):
        pass


ThreadingHTTPServer(('0.0.0.0', 8765), H).serve_forever()
