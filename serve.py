#!/usr/bin/env python3
import os, http.server, socketserver

os.chdir('/Users/razzan/Documents/Claude Projects/MagArkido/MagArkido/Resource')
PORT = 7788
Handler = http.server.SimpleHTTPRequestHandler
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving at http://localhost:{PORT}")
    httpd.serve_forever()
