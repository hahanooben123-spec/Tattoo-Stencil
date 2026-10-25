import io
import threading
import time
from fastapi.testclient import TestClient
from PIL import Image
from LocalStencilServer.server import create_app
from LocalStencilServer.engine import Cancelled, decode, binary_png

TOKEN = "a"*43
AUTH = {"Authorization":"Bearer "+TOKEN}

def picture(size=(64,96)):
    stream = io.BytesIO()
    Image.new("RGB",size,"white").save(stream,format="PNG")
    return stream.getvalue()

class FakeEngine:
    def __init__(self, gate=None): self.gate = gate
    def generate(self, image, cancel, progress):
        progress(0.5,"Testing")
        while self.gate and not self.gate.is_set():
            if cancel.is_set(): raise Cancelled()
            time.sleep(.005)
        output = image.copy()
        output.putpixel((2,2),(128,128,128))
        return output, .1

def wait(client, identifier, status):
    for _ in range(200):
        result = client.get("/v1/jobs/"+identifier,headers=AUTH).json()
        if result["status"] == status: return result
        time.sleep(.01)
    raise AssertionError(result)

def test_authorization_input_validation_and_complete_job():
    with TestClient(create_app(TOKEN,FakeEngine())) as client:
        assert client.get("/v1/health").status_code == 401
        assert client.post("/v1/jobs",content=b"secret",headers=AUTH).status_code == 422
        assert client.post("/v1/jobs",content=picture((8,8)),headers=AUTH).status_code == 422
        response = client.post("/v1/jobs",content=picture(),headers=AUTH)
        assert response.status_code == 202
        identifier = response.json()["id"]
        job = wait(client,identifier,"done")
        assert (job["width"],job["height"]) == (64,96)
        response = client.get("/v1/jobs/"+identifier+"/image",headers=AUTH)
        assert response.headers["Cache-Control"] == "no-store"
        output = Image.open(io.BytesIO(response.content)).convert("L")
        assert set(output.getdata()) == {0,255}
        assert output.getpixel((2,2)) == 0
        assert client.delete("/v1/jobs/"+identifier,headers=AUTH).json()["status"] == "cancelled"
        assert client.get("/v1/jobs/"+identifier+"/image",headers=AUTH).status_code == 409

def test_cancel_running_job_and_bounded_queue():
    gate = threading.Event()
    with TestClient(create_app(TOKEN,FakeEngine(gate))) as client:
        first = client.post("/v1/jobs",content=picture(),headers=AUTH).json()["id"]
        wait(client,first,"running")
        second = client.post("/v1/jobs",content=picture(),headers=AUTH).json()["id"]
        assert client.post("/v1/jobs",content=picture(),headers=AUTH).status_code == 202
        assert client.post("/v1/jobs",content=picture(),headers=AUTH).status_code == 429
        client.delete("/v1/jobs/"+first,headers=AUTH)
        client.delete("/v1/jobs/"+second,headers=AUTH)
        gate.set()
        wait(client,first,"cancelled")
        wait(client,second,"cancelled")

def test_transparency_and_pixel_limit():
    stream = io.BytesIO()
    Image.new("RGBA",(64,64),(0,0,0,0)).save(stream,format="PNG")
    assert decode(stream.getvalue()).getpixel((0,0)) == (255,255,255)
    assert Image.open(io.BytesIO(binary_png(decode(stream.getvalue())))).mode == "1"
