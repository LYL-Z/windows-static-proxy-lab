"""Measure DNS over HTTPS and a resolver's TTL cache against a local TLS receiver.

Requires cryptography and dnspython[doh] 2.7.x. No changes to OS DNS or trust.
"""
import http.client
import datetime
import ipaddress
import json
import secrets
import ssl
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread

import dns.message
import dns.nameserver
import dns.query
import dns.resolver
import dns.rrset
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec


def main():
    records = []
    name = secrets.token_hex(12) + ".invalid."
    with tempfile.TemporaryDirectory(prefix="v69-test-tls-") as folder:
        certificate, key = (Path(folder) / f for f in ("cert.pem", "key.pem"))
        private = ec.generate_private_key(ec.SECP256R1())
        subject = x509.Name([x509.NameAttribute(x509.NameOID.COMMON_NAME, "V69 loopback")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
                .public_key(private.public_key()).serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(minutes=1))
                .not_valid_after(now + datetime.timedelta(hours=1))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
                .sign(private, hashes.SHA256()))
        certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        key.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption()))
        arrivals = []

        class ResolverEndpoint(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                size = int(self.headers.get("Content-Length", 0))
                if self.path != "/dns-query" or self.headers.get("Content-Type") != "application/dns-message" or not 0 < size <= 512:
                    self.send_error(400)
                    return
                query = dns.message.from_wire(self.rfile.read(size))
                if len(query.question) != 1 or query.question[0].name.to_text() != name or query.question[0].rdtype != 1:
                    self.send_error(403)
                    return
                arrivals.append(self.connection.version())
                response = dns.message.make_response(query)
                response.answer.append(dns.rrset.from_text(name, 60, "IN", "A", "192.0.2.1"))
                data = response.to_wire()
                self.send_response(200)
                self.send_header("Content-Type", "application/dns-message")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        with ThreadingHTTPServer(("127.0.0.1", 0), ResolverEndpoint) as endpoint:
            server_tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_tls.load_cert_chain(certificate, key)
            endpoint.socket = server_tls.wrap_socket(endpoint.socket, server_side=True)
            thread = Thread(target=endpoint.serve_forever, daemon=True)
            thread.start()
            try:
                # Empty trust store. The client must reject the fixture certificate.
                conn = http.client.HTTPSConnection("127.0.0.1", endpoint.server_port, timeout=3,
                                                   context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT))
                rejected = False
                try:
                    conn.request("POST", "/dns-query", body=dns.message.make_query(name, "A").to_wire())
                except ssl.SSLCertVerificationError:
                    rejected = True
                finally:
                    conn.close()
                records.append(dict(case="untrusted TLS", verifiedRejection=rejected,
                                    receiverPosts=len(arrivals), passed=rejected and not arrivals))
                resolver = dns.resolver.Resolver(configure=False)
                resolver.nameservers = [dns.nameserver.DoHNameserver(
                    f"https://127.0.0.1:{endpoint.server_port}/dns-query", bootstrap_address="127.0.0.1",
                    verify=str(certificate), http_version=dns.query.HTTPVersion.H1)]
                resolver.cache = dns.resolver.Cache()
                for label, delta in (("cold", 1), ("warm", 0), ("client cache flushed", 1)):
                    if label == "client cache flushed":
                        resolver.cache.flush()
                    start = len(arrivals)
                    answer = resolver.resolve(name, "A", lifetime=4)
                    matched = [item.address for item in answer] == ["192.0.2.1"]
                    posts = len(arrivals) - start
                    records.append(dict(case=label, matched=matched, receiverPosts=posts,
                                        passed=matched and posts == delta))
            finally:
                endpoint.shutdown()
                thread.join()
    print(json.dumps(dict(client="dnspython", destination="IPv4 loopback TLS", rows=records,
                          tls=list(dict.fromkeys(arrivals)), tempRemoved=not Path(folder).exists(),
                          chromeBuiltInDoH="NOT_TESTED", systemResolver="NOT_TESTED"), indent=2))
    return int(not all(row["passed"] for row in records))


if __name__ == "__main__":
    raise SystemExit(main())
