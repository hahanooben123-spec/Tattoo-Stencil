"""Offline visual review of a pilot, including unscored visual-only motifs."""
import argparse
import base64
import json
from pathlib import Path


def embedded(path):
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("experiment", type=Path)
    args = parser.parse_args()
    report = json.loads((args.experiment / "experiment.json").read_text(encoding="utf-8"))
    readiness = json.loads((args.experiment / "data-readiness.json").read_text(encoding="utf-8"))
    provisional = readiness.get("provisionalAlignment", False)
    if provisional:
        notice = "Omtrent sammenpassede collage-par. Usikkerheden i placeringen gør dem uegnede som præcist facit for professionel kvalitet."
    elif readiness.get("scope") == "synthetic-smoke-only":
        notice = "Syntetisk prøve: dette siger intet om kvalitet på rigtige tattoo-motiver."
    else:
        notice = "Træningskandidat: kræver særskilt gennemgang af nye motiver og en tatovørs vurdering."
    items = []
    for record in report["candidate"]:
        before = args.experiment / "baseline" / record["name"]
        after = args.experiment / "candidate" / record["name"]
        items.append({"name": record["name"], "note": "Valideringsmotiv · ikke brugt til træning." +
                      (" Placeringen af facitstreger er foreløbig." if provisional else ""),
                      "source": embedded(after / "source.png"), "target": embedded(after / "structure-target.png"),
                      "before": {mode: embedded(before / f"structure-{mode}.png") for mode in ("raw", "black")},
                      "after": {mode: embedded(after / f"structure-{mode}.png") for mode in ("raw", "black")}})
    visual = args.experiment / "visual-only"
    if visual.exists():
        for folder in sorted(visual.iterdir()):
            if not folder.is_dir():
                continue
            metadata = json.loads((folder / "metadata.json").read_text(encoding="utf-8"))
            items.append({"name": folder.name, "note": metadata["note"], "source": embedded(folder / "source.png"),
                          "target": embedded(folder / "target-reference.png"),
                          "before": {mode: embedded(folder / f"before-{mode}.png") for mode in ("raw", "black")},
                          "after": {mode: embedded(folder / f"after-{mode}.png") for mode in ("raw", "black")}})
    html = '''<!doctype html><html lang="da"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Foreløbigt stencil-træningsforsøg</title><style>
*{box-sizing:border-box}body{font:16px system-ui,sans-serif;background:#eee;color:#222;margin:0}header{background:white;padding:24px}h1{font-size:24px;margin:0 0 12px}p{max-width:1000px;line-height:1.5}select,button{font:inherit;padding:8px 12px;margin:4px}main{padding:20px}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}article{padding:12px;background:white}h2{font-size:16px}img{width:100%;height:auto;cursor:zoom-in}dialog{max-width:98vw;max-height:98vh;border:0}dialog img{max-width:94vw;max-height:88vh;width:auto;height:auto}dialog::backdrop{background:#000b}@media(max-width:800px){.grid{grid-template-columns:1fr 1fr}}@media(max-width:480px){.grid{grid-template-columns:1fr}}
</style><header><h1>Foreløbigt stencil-træningsforsøg</h1>
<p><strong>Ikke en færdig stencil-motor.</strong> Trænet lokalt på __TRAIN_COUNT__ træningspar. Ingen betalt tjeneste eller upload. __NOTICE__</p>
<p id="note"></p><select id="motif" aria-label="Motiv"></select><button id="mode">Vis rå modelskitse</button>
<p>Sorte versioner bruger samme faste grænseværdi (0,5) før og efter træning. Grå modelskitser er alene til inspektion. Der er ingen manuelt indtegnede reparationer af modellens resultat.</p></header>
<main><div class="grid"><article><h2>Originalt motivudsnit</h2><img id="source" alt="Motiv"></article>
<article><h2>Din eksempelstencil</h2><img id="target" alt="Eksempelstencil"></article>
<article><h2>Oprindelig model</h2><img id="before" alt="Før træning"></article>
<article><h2>Efter foreløbig træning</h2><img id="after" alt="Efter træning"></article></div>
<p>Tryk på et billede for fuld størrelse. Et råt skitsebillede kan se bedre ud end den sorte udgave. Begge trin skal fungere, før modellen er brugbar. Skyggeguides er ikke særskilt trænet i dette forsøg.</p></main>
<dialog id="zoom"><button id="close">Luk</button><br><img id="large" alt="Forstørret"></dialog>
<script>const data=__DATA__;const $=id=>document.getElementById(id);let mode='black';
data.forEach((item,index)=>{let option=document.createElement('option');option.value=index;option.textContent=item.name;$('motif').append(option)});
const eye=data.findIndex(v=>v.name==='eye');$('motif').value=Math.max(0,eye);
function update(){const v=data[Number($('motif').value)];$('source').src=v.source;$('target').src=v.target;$('before').src=v.before[mode];$('after').src=v.after[mode];$('note').textContent=v.note;$('mode').textContent=mode==='black'?'Vis rå modelskitse':'Vis sorte streger'}
$('motif').onchange=update;$('mode').onclick=()=>{mode=mode==='black'?'raw':'black';update()};
document.querySelectorAll('article img').forEach(img=>img.onclick=()=>{$('large').src=img.src;$('zoom').showModal()});$('close').onclick=()=>$('zoom').close();update();
</script></html>'''
    html = html.replace("__TRAIN_COUNT__", str(readiness["splits"]["train"])).replace("__NOTICE__", notice)
    html = html.replace("__DATA__", json.dumps(items, ensure_ascii=True).replace("</", "<\\/"))
    (args.experiment / "review.html").write_text(html, encoding="utf-8")
    print(args.experiment / "review.html")


if __name__ == "__main__":
    main()
