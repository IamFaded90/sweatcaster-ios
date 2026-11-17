from pathlib import Path
import json
root_path = Path(__file__).resolve().parents[1]
data=json.loads((root_path / 'App/Assets/Village/final/characters.json').read_text())
html='''<!doctype html><meta charset="utf-8"><title>FadedAI · Grafikprøve</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#0b1f28;color:#f3f5ed;font:16px system-ui;padding:32px}h1{font-size:40px;letter-spacing:-1.6px;margin:4px 0 12px}p{color:#bfd0d1;line-height:1.5}.note{color:#f5d09a}button{font:inherit;color:inherit;background:linear-gradient(140deg,#ffffff18,#ffffff06);border:1px solid #60777b;border-radius:14px;padding:12px 18px;cursor:pointer}button.active{color:#10271e;background:linear-gradient(120deg,#d3f5a8,#83dbc5)}nav{display:flex;gap:12px;margin:24px 0}.cards{display:grid;grid-template-columns:repeat(5,minmax(135px,1fr));gap:16px}.card{background:linear-gradient(145deg,#ffffff17,#ffffff04);border:1px solid #435e67;border-radius:24px;padding:16px;text-align:center}.card canvas{width:128px;height:128px;image-rendering:pixelated}.card h2{font-size:18px;margin:4px}.card p{font-size:13px;margin:4px}.map{height:690px;max-width:100%;object-fit:contain;border-radius:24px}.rooms{display:grid;grid-template-columns:repeat(2,1fr);gap:20px}.rooms img{width:100%;height:300px;object-fit:contain}.hidden{display:none}.portraits{display:flex;gap:24px}.portraits canvas{max-width:40%;height:460px;object-fit:contain;border-radius:22px}.controls{display:flex;gap:12px;align-items:center;flex-wrap:wrap;padding:14px 0 22px}input{accent-color:#bdeb9f;width:200px}@media(max-width:700px){body{padding:18px}.cards{grid-template-columns:repeat(2,1fr)}.rooms{grid-template-columns:1fr}h1{font-size:28px}nav{flex-wrap:wrap}}
</style>
<p class="note">GRAFIKPRØVE · Dette er en kontrol af billedfilerne, ikke en kørende iPhone-app.</p>
<h1>Dit hold. Dit sted.</h1><p>5 mænd + 5 kvinder · egne figurer · café, studie, kontor, sovekrog og kirkegård</p>
<nav><button class="active" data-tab="figures">Figurer</button><button data-tab="map">Landsbyen</button><button data-tab="rooms">Alle rum</button><button data-tab="portraits">Harper & Lumi</button></nav>
<section id="figures"><div class="controls"><label>Retning <input aria-label="Retning" type="range" id="direction" min="0" max="15" value="0"></label><button id="walk" class="active">Gå</button><span id="status">Indlæser grafik…</span></div><div class="cards"></div></section>
<section id="map" class="hidden"><button id="day">Dag / nat</button><br><img class="map" id="mapImage" src="../App/Assets/Village/final/map-night.png"></section>
<section id="rooms" class="rooms hidden"></section><section id="portraits" class="portraits hidden"></section>
<script>
const atlases=ATLAS_DATA;
const root='../App/Assets/Village/final/';
const descriptions={adam:'Briller · petroljakke',atlas:'Blond · værktøjsbælte',milo:'Hue · grøn skjorte',noah:'Hovedtelefoner · lys frakke',theo:'Hestehale · kamera',eva:'Krøller · gul jakke',luna:'Sølvhår · hættetrøje',iris:'Fletning · grøn blazer',nova:'Pink hår · limejakke',saga:'Lys fletning · strik'};
let walking=true,night=true,ready=0;const items=[];
for(const name of ['adam','atlas','milo','noah','theo','eva','luna','iris','nova','saga']){
 const card=document.createElement('div');card.className='card';card.innerHTML=`<canvas width="128" height="128" aria-label="${name}"></canvas><h2>${name[0].toUpperCase()+name.slice(1)}</h2><p>${descriptions[name]}</p>`;document.querySelector('.cards').append(card);
 const img=new Image();img.onload=()=>{ready++;document.querySelector('#status').textContent=ready+' af 10 figurer indlæst'};img.src=root+'walk-'+name+'.png';items.push({name,img,ctx:card.querySelector('canvas').getContext('2d')});
}
const portraits=[];for(const name of ['harper','lumi']){const canvas=document.createElement('canvas');canvas.width=512;canvas.height=768;canvas.setAttribute('aria-label',name);document.querySelector('#portraits').append(canvas);const img=new Image();img.src=root+'expressions-'+name+'.png';portraits.push({img,ctx:canvas.getContext('2d')})}
for(const [name,label] of [['room-cafe','Café'],['room-research-lab','Forskningsværksted'],['room-media-studio','Mediestudie'],['room-sleeping-corner','Sovekrog'],['cemetery','Kirkegården'],['personal-office','Personligt kontor'],['office-slice','Skaberens værksted']]){const card=document.createElement('div');card.className='card';card.innerHTML=`<img src="${root+name}.png"><h2>${label}</h2>`;document.querySelector('#rooms').append(card)}
document.querySelectorAll('nav button').forEach(button=>button.onclick=()=>{document.querySelectorAll('section').forEach(x=>x.classList.toggle('hidden',x.id!==button.dataset.tab));document.querySelectorAll('nav button').forEach(x=>x.classList.toggle('active',x===button))});
document.querySelector('#walk').onclick=()=>{walking=!walking;document.querySelector('#walk').classList.toggle('active',walking);document.querySelector('#walk').textContent=walking?'Gå':'Stå stille'};
document.querySelector('#day').onclick=()=>{night=!night;document.querySelector('#mapImage').src=root+(night?'map-night.png':'map-day.png')};
function draw(ms){const direction=+document.querySelector('#direction').value;for(const item of items){if(!item.img.complete||!item.img.naturalWidth)continue;const atlas=atlases[item.name];const row=Math.round(direction/16*atlas.rows.length)%atlas.rows.length;const frames=atlas.rows[row];const step=walking?Math.floor(ms/125)%8:0;const frame=frames[Math.floor(step*frames.length/8)];const s=104/atlas.maxHeight;item.ctx.clearRect(0,0,128,128);item.ctx.imageSmoothingEnabled=false;item.ctx.drawImage(item.img,frame.x,frame.y,frame.width,frame.height,(128-frame.width*s)/2,114-frame.height*s,frame.width*s,frame.height*s)}for(const item of portraits){if(!item.img.complete||!item.img.naturalWidth)continue;const index=Math.floor(ms/650)%4,w=item.img.naturalWidth/2,h=item.img.naturalHeight/2;item.ctx.drawImage(item.img,(index%2)*w,Math.floor(index/2)*h,w,h,0,0,512,768)}requestAnimationFrame(draw)}requestAnimationFrame(draw);
</script>'''.replace('ATLAS_DATA',json.dumps(data))
output = root_path / 'build/village-preview.html'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(html,encoding='utf-8')
print(output)
