"""Build a self-contained, offline review page from compare.py results."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

from PIL import Image
from compare import contact_sheet


def embedded(path: Path) -> str:
    return "data:image/png;base64,"+base64.b64encode(path.read_bytes()).decode("ascii")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report = json.loads((args.output / "report.json").read_text(encoding="utf-8"))
    items = []
    for record in report["images"]:
        folder = args.output / record["name"]
        models = list(record["models"])
        labels = ["Reference"]+(["Current engine (no Vision)"] if (folder / "baseline.png").exists() else [])+models
        contact_sheet(folder, Image.open(folder / "reference.png"), labels)
        items.append({"name": record["name"], "reference": embedded(folder / "reference.png"),
                      "target": embedded(folder / "artist-target.png") if (folder / "artist-target.png").exists() else None,
                      "baseline": embedded(folder / "baseline.png") if (folder / "baseline.png").exists() else None,
                      "models": {model: {"raw": embedded(folder / model / "raw.png"),
                                         "black": embedded(folder / model / "stencil.png"),
                                         "cpuSeconds": record["models"][model]["inferenceSecondsCPU"]}
                                 for model in models}})
    html = r'''<!doctype html><html lang="da"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Stencil · lokal modelprototype</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#efeeeb;color:#222;font:15px system-ui,sans-serif}
header{padding:22px 28px;background:white;border-bottom:1px solid #ddd}h1{font-size:23px;margin:0 0 8px}
p{margin:6px 0;color:#555;max-width:950px;line-height:1.5}nav{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:16px}
select,button{font:inherit;border:1px solid #aaa;border-radius:8px;padding:9px 12px;background:white;color:#222}
button[aria-pressed=true]{background:#202b29;color:white;border-color:#202b29}main{padding:22px;max-width:1700px;margin:auto}
.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:16px}article{background:white;padding:12px;border-radius:10px}
.grid.with-target{grid-template-columns:repeat(4,minmax(0,1fr))}[hidden]{display:none!important}
h2{font-size:15px;margin:0 0 10px}article img{display:block;width:100%;height:auto;cursor:zoom-in}
.note{font-size:13px;margin-top:14px}dialog{border:0;max-width:97vw;max-height:97vh;padding:10px;background:white;border-radius:8px}
dialog::backdrop{background:#000b}dialog img{display:block;max-height:88vh;max-width:92vw}#close{float:right;margin-bottom:8px}
@media(max-width:800px){.grid,.grid.with-target{grid-template-columns:1fr}header{padding:18px}main{padding:12px}}
</style>
<header><h1>Stencil · lokal modelprototype</h1>
<p>Ingen billed-upload eller betalt API. Samme billedudsnit bruges til alle modeller. Ingen manuelt markerede øjne.</p>
<p>Stil 1 er den mest lovende kandidat. Modelskitsen er gråtoner; stencilversionen bruger udelukkende sorte linjer på hvidt.</p>
<nav><select id="image" aria-label="Billedudsnit"></select><select id="model" aria-label="Model">
<option value="drawings-style1">Informative Drawings · stil 1</option><option value="teed">TEED</option>
<option value="drawings-style2">Informative Drawings · stil 2</option></select>
<button id="showBaseline" aria-pressed="false">Vis eksisterende motor</button></nav></header>
<main><div class="grid"><article><h2>Reference · beskåret input</h2><img id="reference" alt="Reference"></article>
<article id="targetPanel" hidden><h2>Eksempelstencil · kun til sammenligning</h2><img id="target" alt="Brugerens eksempelstencil"></article>
<article><h2 id="middleTitle">Rå modelskitse</h2><img id="raw" alt="Modelskitse"></article>
<article><h2>Sorte linjer · prototype</h2><img id="black" alt="Sort stencilprototype"></article></div>
<p id="timing" class="note"></p>
<p class="note">Tryk på et billede for større visning. Eksisterende motor er den portable Swift-motor uden Apple Vision.
Input er beskårne referencebilleder. Eksempelstenciler indgår ikke i modellernes input. Collagepaneler er ikke geometrisk registrerede træningspar; en tatovering på hud har også anden geometri. Reflekser, rammer og UI-symboler kan følge med.</p>
<p class="note">Prototype til vurdering. Genererede streger kan afvige fra originalens former. Øjne, placering og overførselsværdi er ikke godkendt af en tatovør. Ingen model er indbygget i iPad-appen endnu.</p></main>
<dialog id="zoom"><button id="close">Luk</button><img id="large" alt="Forstørret visning"></dialog>
<script>const items=__DATA__;const $=id=>document.getElementById(id);let baseline=false;
items.forEach((v,i)=>{const o=document.createElement('option');o.value=i;o.textContent=v.name;$('image').append(o)});
$('image').value=Math.max(0,items.findIndex(v=>v.name==='target-art'));
function update(){const item=items[Number($('image').value)],model=item.models[$('model').value],showBaseline=baseline&&!!item.baseline;
$('reference').src=item.reference;$('raw').src=showBaseline?item.baseline:model.raw;$('black').src=model.black;
$('targetPanel').hidden=!item.target;document.querySelector('.grid').classList.toggle('with-target',!!item.target);
if(item.target){$('target').src=item.target}else{$('target').removeAttribute('src')}
$('middleTitle').textContent=showBaseline?'Eksisterende motor · uden Vision':'Rå modelskitse';
$('showBaseline').disabled=!item.baseline;$('showBaseline').setAttribute('aria-pressed',showBaseline);
$('timing').textContent='En lokal CPU-kørsel: '+model.cpuSeconds.toFixed(2)+' sek. for modelberegning. Modelindlæsning, oprydning og filskrivning er ikke medregnet. Dette er ikke en iPad-måling.';}
['image','model'].forEach(id=>$(id).addEventListener('change',update));$('showBaseline').onclick=()=>{baseline=!baseline;update()};
document.querySelectorAll('article img').forEach(el=>el.onclick=()=>{$('large').src=el.src;$('zoom').showModal()});
$('close').onclick=()=>$('zoom').close();update();</script></html>'''
    html = html.replace("__DATA__", json.dumps(items, ensure_ascii=True).replace("</", "<\\/"))
    (args.output / "review.html").write_text(html, encoding="utf-8")
    print(args.output / "review.html")


if __name__ == "__main__":
    main()
