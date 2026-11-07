#!/usr/bin/env python3
"""update-fault-server.py — tiny loopback HTTP server for update failure injection.

Usage: update-fault-server.py <mode> <port> <directory>
  mode=normal   serve <directory> as static files (signed feed)
  mode=http500  answer every request with HTTP 500

Binds 127.0.0.1 only. Used by the update-flow E2E; never exposed off-host.
"""
import sys
import http.server
import socketserver

mode = sys.argv[1]
port = int(sys.argv[2])
directory = sys.argv[3]


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=directory, **kw)

    def do_GET(self):
        if mode == "http500":
            self.send_error(500, "Injected 500 for update fault test")
            return
        return super().do_GET()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", port), Handler) as httpd:
    httpd.serve_forever()
