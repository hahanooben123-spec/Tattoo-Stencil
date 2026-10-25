"""Private end-to-end HTTPS test against a running local PC server."""
import io
import json
import ssl
import time
import urllib.request
from pathlib import Path
from PIL import Image
from .run import ROOT

def main():
    config = json.loads((ROOT/"credentials.json").read_text())
    base = f"https://{config['address']}:8765"
    tls = ssl.create_default_context(cafile=str(ROOT/"cert.pem"))
    # Do not use system proxies for this explicitly private LAN destination.
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPSHandler(context=tls))
    def request(path, method="GET", data=None):
        req = urllib.request.Request(base+path,data=data,method=method,
                                     headers={"Authorization":"Bearer "+config["token"],"Content-Type":"application/octet-stream"})
        with client.open(req,timeout=30) as response: return response.read()
    print(json.loads(request("/v1/health")),flush=True)
    folder = Path("Validation/Results/flux-klein")
    for name, path in [("eye","Validation/PrivateReferences/new-pairs/eye/source.png"),
                       ("masked-portrait","Validation/Results/model-prototype/masked-portrait/reference.png")]:
        start = time.monotonic()
        job = json.loads(request("/v1/jobs","POST",Path(path).read_bytes()))
        identifier = job["id"]
        while job["status"] not in {"done","error","cancelled"}:
            if time.monotonic()-start > 900: raise TimeoutError("PC generation timed out")
            time.sleep(1)
            job = json.loads(request("/v1/jobs/"+identifier))
        if job["status"] != "done": raise RuntimeError(job["message"])
        data = request("/v1/jobs/"+identifier+"/image")
        image = Image.open(io.BytesIO(data))
        assert image.mode == "1"
        (folder/(name+"-api-binary.png")).write_bytes(data)
        # Public metadata only, never print the credentials/pairing payload.
        print(name,{"width":job["width"],"height":job["height"],"generationSeconds":job["seconds"],
                    "roundTripSeconds":round(time.monotonic()-start,2)},flush=True)
        request("/v1/jobs/"+identifier,"DELETE")

if __name__ == "__main__": main()
