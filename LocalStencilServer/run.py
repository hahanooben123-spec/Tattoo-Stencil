"""Start private HTTPS server and write a local pairing QR (never served on LAN)."""
import argparse
import datetime
import hashlib
import html
import io
import ipaddress
import json
import secrets
import socket
import base64
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
import qrcode
import uvicorn
from .server import create_app

ROOT = Path(__file__).resolve().parents[1] / ".tools/local-stencil/runtime"

def default_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        # UDP connect selects the local route; sends no packets.
        sock.connect(("192.0.2.1", 9))
        return sock.getsockname()[0]

def prepare(address, port):
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or not (ip.is_private and not ip.is_unspecified and not ip.is_link_local):
        raise ValueError("Vælg PC'ens private IPv4-adresse.")
    ROOT.mkdir(parents=True, exist_ok=True)
    credentials = ROOT/"credentials.json"
    if credentials.exists():
        config = json.loads(credentials.read_text())
    else:
        config = {"token":secrets.token_urlsafe(32)}
    cert_path, key_path = ROOT/"cert.pem", ROOT/"key.pem"
    if config.get("address") != address or not cert_path.exists() or not key_path.exists():
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Stencil PC")])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5))
                .not_valid_after(now+datetime.timedelta(days=365))
                .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ip)]),critical=False)
                .sign(key,hashes.SHA256()))
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        config["address"] = address
        credentials.write_text(json.dumps(config))
    cert = x509.load_pem_x509_certificate(cert_path.read_bytes())
    pairing = {"version":1,"url":f"https://{address}:{port}","token":config["token"],
               "fingerprint":cert.fingerprint(hashes.SHA256()).hex()}
    payload = json.dumps(pairing, separators=(",",":"))
    png = io.BytesIO()
    qrcode.make(payload).save(png,format="PNG")
    # The JSON can also be copied into the app, avoiding camera permissions/setup.
    (ROOT/"pairing.html").write_text("<!doctype html><meta charset='utf-8'><title>Stencil PC</title>"
        "<style>body{font:20px system-ui;max-width:720px;margin:40px auto}img{width:420px;max-width:100%}"
        "textarea{width:100%;height:150px}</style><h1>Forbind Stencil Studio</h1>"
        "<p>Begge enheder skal være på samme private netværk. I appen: Forbind PC → indsæt parringskoden.</p>"
        f"<img src='data:image/png;base64,{base64.b64encode(png.getvalue()).decode()}' alt='Parringskode'>"
        f"<p>Kopiér hele koden herunder til appen. Hold koden privat.</p><textarea readonly>{html.escape(payload)}</textarea>",
        encoding="utf-8")
    return config,cert_path,key_path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--address", default=None)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    address = args.address or default_address()
    config, cert, key = prepare(address,args.port)
    print("Parringsside:", ROOT/"pairing.html", flush=True)
    print(f"Stencil PC: https://{address}:{args.port} · luk konsollen for at stoppe", flush=True)
    uvicorn.run(create_app(config["token"]),host=address,port=args.port,
                ssl_certfile=str(cert),ssl_keyfile=str(key),access_log=False)

if __name__ == "__main__":
    main()
