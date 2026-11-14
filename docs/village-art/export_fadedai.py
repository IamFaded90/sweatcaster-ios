"""Original FadedAI vector and raster sources. Run with Python + Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw
import math,json
ROOT=Path(__file__).resolve().parents[1]/'assets'/'fadedai';ROOT.mkdir(parents=True,exist_ok=True)
COLORS=['#65b6ff','#be97ff','#edb566','#82d5b8','#f3919b','#d5afe8','#a6bff0','#e9ce85','#6ecfdd','#bed39f']
NAMES=['adam','eva','atlas','luna','milo','iris','noah','nova','saga','theo']
manifest={'license':'CC0-1.0','projection':'isometric 2:1; x=(u-v)*30, y=(u+v)*15-z*30','assets':[]}
class Canvas:
 def __init__(self,w,h):
  self.w=w;self.h=h;self.im=Image.new('RGBA',(w,h));self.d=ImageDraw.Draw(self.im);self.parts=[]
 def poly(self,pts,c):
  self.d.polygon(pts,fill=c);self.parts.append(f'<polygon points="{" ".join(f"{x},{y}" for x,y in pts)}" fill="{c}"/>')
 def ellipse(self,x,y,rx,ry,c):
  self.d.ellipse((x-rx,y-ry,x+rx,y+ry),fill=c);self.parts.append(f'<ellipse cx="{x}" cy="{y}" rx="{rx}" ry="{ry}" fill="{c}"/>')
 def rect(self,x,y,w,h,c,r=0):
  self.d.rounded_rectangle((x,y,x+w,y+h),radius=r,fill=c);self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{c}"/>')
 def line(self,pts,c,w):
  self.d.line(pts,fill=c,width=max(1,round(w)));self.parts.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in pts)}" fill="none" stroke="{c}" stroke-width="{w}" stroke-linecap="round"/>')
 def save(self,name,anchor=None,**meta):
  self.im.save(ROOT/(name+'.png'));(ROOT/(name+'.svg')).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}"><g id="editable-artwork">'+''.join(self.parts)+'</g></svg>',encoding='utf-8');manifest['assets'].append({'name':name,'dimensions':[self.w,self.h],'anchor':anchor or [self.w/2,self.h/2],**meta})
class World:
 def __init__(self,c,ox,oy,s=1):self.c=c;self.ox=ox;self.oy=oy;self.s=s
 def p(self,x,y,z=0):return(self.ox+(x-y)*30*self.s,self.oy+((x+y)*15-z*30)*self.s)
 def poly(self,pts,c):self.c.poly([self.p(*p) for p in pts],c)
 def base(self,x,y,a,b,z,c):
  self.poly([(x,y,z),(a,y,z),(a,b,z),(x,b,z)],c);self.poly([(x,b,z),(a,b,z),(a,b,z-.3),(x,b,z-.3)],'#233d4c');self.poly([(a,y,z),(a,b,z),(a,b,z-.3),(a,y,z-.3)],'#162d3d')
 def building(self,x,y,w,d,c):
  a=x+w;b=y+d;self.base(x-.2,y-.2,a+.2,b+.2,.1,'#35565b');self.poly([(x,b,0),(a,b,0),(a,b,1.65),(x,b,1.65)],'#2c4253');self.poly([(a,y,0),(a,b,0),(a,b,1.65),(a,y,1.65)],'#1d2f42');self.base(x-.15,y-.15,a+.15,b+.15,1.75,'#4a6372');self.base(x+.15,y+.15,a-.15,b-.15,1.8,'#1f3343');self.poly([(x+.2,b+.01,.6),(a-.2,b+.01,.6),(a-.2,b+.01,1.4),(x+.2,b+.01,1.4)],c);self.poly([(a+.01,y+.2,.6),(a+.01,b-.2,.6),(a+.01,b-.2,1.4),(a+.01,y+.2,1.4)],c)
  for k in range(1,4):xx=x+w*k/4;self.c.line([self.p(xx,b+.02,.6),self.p(xx,b+.02,1.4)],'#2c4253',2*self.s)
  self.base(x+.2,y+.2,x+.8,y+.7,1.94,c)
 def tree(self,x,y):
  self.c.line([self.p(x,y),self.p(x,y,1.5)],'#545b5b',4*self.s)
  for k in range(3):
   z=.5+k*.35;self.poly([(x-.45,y,z),(x,y-.45,z),(x,y,z+1.05)],'#316e67');self.poly([(x,y-.45,z),(x+.45,y,z),(x,y+.45,z),(x,y,z+1.05)],'#1f5355')
def bot(c,x,y,i,state='idle',frame=0,direction=0,scale=1):
 s=scale;bob=math.sin(frame*math.pi/4)*s if state in ['walk','talk','work'] else 0
 c.ellipse(x,y,13*s,5*s,'#152738')
 if state=='sleep':
  c.rect(x-24*s,y-15*s,48*s,13*s,COLORS[i],6*s);c.ellipse(x-20*s,y-13*s,9*s,8*s,'#d9b59a');return
 if state=='rest':y+=6*s
 c.rect(x-9*s,y-27*s+bob,18*s,21*s,COLORS[i],5*s)
 skin=['#d9b59a','#b98468','#e3bd9e','#98735b'][i%4]
 c.ellipse(x,y-38*s+bob,10*s,11*s,skin);c.ellipse(x-2*s,y-44*s+bob,10*s,7*s,'#292a3a')
 if i==1:c.ellipse(x-10*s,y-40*s,6*s,7*s,COLORS[i])
 if direction not in range(6,11):
  for dx in [-4,4]:c.ellipse(x+dx*s,y-37*s+bob,1.3*s,1.5*s,'#182637')
 if i==0:c.line([(x-8*s,y-39*s+bob),(x+8*s,y-39*s+bob)],'#5de1d3',2*s)
 for dx in [-5,5]:
  stride=math.sin(frame*math.pi/4)*4*s*(1 if dx>0 else -1) if state=='walk' else 0;c.line([(x+dx*s,y-7*s),(x+dx*s+stride,y)],'#1b2639',5*s)
 arm=math.sin(frame*math.pi/4)*8*s if state in ['talk','work'] else 0
 c.line([(x-9*s,y-23*s),(x-14*s,y-12*s-arm)],COLORS[i],4*s);c.line([(x+9*s,y-23*s),(x+14*s,y-12*s-arm)],COLORS[i],4*s)
 if state=='work':c.rect(x-13*s,y-22*s,26*s,13*s,'#335c6c',2*s);c.rect(x-10*s,y-20*s,20*s,8*s,'#78e1d4',1*s)
for day in [False,True]:
 c=Canvas(1536,1024);c.rect(0,0,1536,1024,'#1a343c' if day else '#0c1a27',0);w=World(c,768,480,1.7);c.ellipse(768,650,650,230,'#091620');w.base(-6.5,-6.5,6.5,6.5,0,'#3d6863' if day else '#234449');w.base(-5.8,-.5,5.8,.5,.03,'#4c6c6e');w.base(-.5,-5.8,.5,5.8,.04,'#4c6c6e');w.base(-1.4,-1.4,1.4,1.4,.06,'#5a7c7d')
 for x,y in [(-6,-5),(-5,-6),(5,-6),(6,-4),(-6,4),(-4,6),(5,5),(6,3),(-6,1),(1,-6),(2,6)]:w.tree(x,y)
 for x,y,ww,d,i in [(-4.8,-4.6,2.6,1.9,0),(1.5,-4.5,2.8,1.8,1),(-4.7,1.7,2.6,1.8,2),(2,2,2.5,1.8,3)]:w.building(x,y,ww,d,COLORS[i])
 c.save('map-'+('day' if day else 'night'),[768,480],layers=['background','ground','paths','trees','buildings'],note='No text or status; bots are separate overlays')
for i,name in enumerate(NAMES):
 c=Canvas(320,256);w=World(c,160,180,1.3);w.base(-2,-1.5,2,1.5,0,'#30424d');w.building(-1.4,-.8,1.5,1,COLORS[i]);x,y=w.p(1,1);bot(c,x,y,i,scale=1.2);c.save('room-'+name,[160,180],bot=i)
 for state in ['idle','walk','work','talk','rest','sleep']:
  c=Canvas(768,1536)
  for direction in range(16):
   for frame in range(8):bot(c,frame*96+48,direction*96+82,i,state,frame,direction)
  c.save('bot-'+name+'-'+state,[48,82],cell=[96,96],columns=8,rows=16,fps=8 if state in ['walk','talk','work'] else 4,directions='row 0 south; clockwise in 22.5 degree increments; stylized shared silhouettes')
for i,label in enumerate(['research','atelier','social','rest']):
 c=Canvas(320,256);w=World(c,160,180,1.6);w.building(-1.3,-.95,2.6,1.9,COLORS[i]);c.save('building-'+label,[160,180])
c=Canvas(128,192);w=World(c,64,160,1.6);w.tree(0,0);c.save('tree',[64,160])
for icon in ['map','office','tasks','computer','files','settings','home','chat','share','retry','cancel','live']:
 c=Canvas(48,48)
 if icon=='cancel':c.line([(14,14),(34,34)],'#5de1d3',3);c.line([(34,14),(14,34)],'#5de1d3',3)
 elif icon in ['office','computer','live']:c.rect(8,9,32,24,'#5de1d3',4);c.rect(11,12,26,18,'#111d2b',2);c.line([(24,33),(24,40),(34,40),(14,40)],'#5de1d3',3)
 elif icon=='map':c.poly([(7,15),(24,6),(41,15),(24,24)],'#5de1d3');c.line([(7,25),(24,34),(41,25)],'#5de1d3',3);c.line([(7,33),(24,42),(41,33)],'#5de1d3',3)
 else:
  c.rect(11,6,26,36,'#5de1d3',5);c.rect(14,9,20,30,'#111d2b',3)
  for y in [17,24,31]:c.line([(18,y),(30,y)],'#5de1d3',2)
 c.save('icon-'+icon,[24,24])
(ROOT/'manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
print(f'Exported {len(manifest["assets"])} editable SVGs and PNGs to {ROOT}')
