#!/usr/bin/env python3
"""Independent scalar reference: LightCraft PointK at 4f0b110 (MIT).
No Swift/Metal functions or generated code are imported. Re-run to reproduce JSON.
Native RGB integration uses the existing 2021 linear-sRGB matrices and radial map;
raw LCh cases test the upstream equations independently of working RGB primaries.
"""
import json, math, uuid
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent

def smooth(a,b,x):
    t = max(0,min(1,(x-a)/(b-a)))
    return t*t*(3-2*t)
def wrap(x): return x - 2*math.pi*math.floor((x+math.pi)/(2*math.pi))
def point(i=1, **kw):
    p = dict(id=str(uuid.UUID(int=i)),lightness=.6,chroma=.1,hue=40.,hueShift=0.,saturationShift=0.,luminanceShift=0.,variance=0.,range=50.,hueRange=50.,saturationRange=50.,luminanceRange=50.)
    p.update(kw); return p

def coefficients(p):
    k=max(p['range']/50,.05)
    return (.1+.6*p['hueRange']/100)*k, (.02+.12*p['saturationRange']/100)*k, (.05+.4*p['luminanceRange']/100)*k

def weight(p,x):
    l,c,h=x; wh,wc,wl=coefficients(p)
    hue = 1 if p['chroma'] < .02 else (1-smooth(wh/2,wh,abs(wrap(h-math.radians(p['hue'])))))*smooth(.005,.025,c)
    return hue*(1-smooth(wc/2,wc,abs(c-p['chroma'])))*(1-smooth(wl/2,wl,abs(l-p['lightness'])))
def apply(p,x):
    l,c,h=x; w=weight(p,x); v=p['variance']/100*.8
    return [l+w*(v*(l-p['lightness'])+p['luminanceShift']/100*.2),max(0,(c+w*v*(c-p['chroma']))*(1+w*p['saturationShift']/100)),h+w*(v*wrap(h-math.radians(p['hue']))+p['hueShift']/100*.5)]
def lab(rgb):
    rows = [[.4122214708,.5363325363,.0514459929],[.2119034982,.6806995451,.1073969566],[.0883024619,.2817188376,.6299787005]]
    l,m,s=[math.copysign(abs(sum(a*b for a,b in zip(row,rgb)))**(1/3),sum(a*b for a,b in zip(row,rgb))) for row in rows]
    return [.2104542553*l+.7936177850*m-.0040720468*s,1.9779984951*l-2.4285922050*m+.4505937099*s,.0259040371*l+.7827717662*m-.8086757660*s]
def rgb(v):
    l,a,b=v
    x=(l+.3963377774*a+.2158037573*b)**3
    y=(l-.1055613458*a-.0638541728*b)**3
    z=(l-.0894841775*a-1.2914855480*b)**3
    return [4.0767416621*x-3.3077115913*y+.2309699292*z,-1.2684380046*x+2.6097574011*y-.3413193965*z,-.0041960863*x-.7034186147*y+1.7076147010*z]
def gamut(v):
    l,a,b=v; l=max(0,min(1,l))
    def inside(c): return all(-1e-7 <= x <= 1.0000001 for x in c)
    c=rgb([l,a,b])
    if not inside(c):
        lo,hi=0.,1.
        for _ in range(16):
            mid=(lo+hi)/2
            if inside(rgb([l,a*mid,b*mid])): lo=mid
            else: hi=mid
        c=rgb([l,a*lo,b*lo])
    return [max(0,min(1,x)) for x in c]
raw=[]
for variance in [-100.,0.,100.]:
  for spread in [0.,50.,100.]:
    for hue,c,l in [(40,.1,.6),(41,.1,.6),(399,.14,.68),(-319,.12,.62),(220,.1,.6),(0,.001,.6),(40,.005,.6),(40,.015,.6),(40,.025,.6),(40,.3,.1)]:
      p=point(variance=variance,range=spread,hueShift=60.,saturationShift=-50.,luminanceShift=25.)
      x=[l,c,math.radians(hue)]
      raw.append(dict(sample=p,input=x,weight=weight(p,x),output=apply(p,x)))
for c in [0.,.001,.019999,.02]:
  p=point(chroma=c,hue=359.,hueShift=100.,variance=-100.,range=100.)
  x=[.61,.01,math.radians(180)]
  raw.append(dict(sample=p,input=x,weight=weight(p,x),output=apply(p,x)))
for axis,coordinate in [('hueRange',2),('saturationRange',1),('luminanceRange',0)]:
  for limit in [0.,100.]:
    p=point(**{axis:limit},hueShift=-100.,saturationShift=100.,luminanceShift=-100.,variance=100.)
    widths=coefficients(p)
    width=widths[{'hueRange':0,'saturationRange':1,'luminanceRange':2}[axis]]
    for distance in [0.,.75,1.]:
      x=[p['lightness'],p['chroma'],math.radians(p['hue'])]
      x[coordinate]+=width*distance
      raw.append(dict(sample=p,input=x,weight=weight(p,x),output=apply(p,x)))
colors=[[.42,.18,.09],[.1,.3,.6],[.6,.3,.1],[.2,.2,.2],[0.,0.,0.],[1.,1.,1.],[-.04,.2,.4],[1.1,.8,.3]]
base=lab(colors[0]); h=(math.degrees(math.atan2(base[2],base[1]))+360)%360
p=point(lightness=base[0],chroma=math.hypot(base[1],base[2]),hue=h,hueShift=65.,saturationShift=-35.,luminanceShift=30.,variance=-55.,range=100.)
linear=[]
for count in [1,2,8]:
  samples=[dict(p,id=str(uuid.UUID(int=i+1)),hueShift=65.-i*12,variance=(-55.+i*10)) for i in range(count)]
  for color in colors:
    l,a,b=lab(color); x=[l,math.hypot(a,b),math.atan2(b,a)]
    for sample in samples: x=apply(sample,x)
    result=gamut([x[0],x[1]*math.cos(x[2]),x[1]*math.sin(x[2])])
    linear.append(dict(samples=samples,rgb=color,linear=result))
value=dict(upstream='4f0b110bcbd2e350c6d97b47f1d824c2222295c4',upstreamEquations='PointK::new/weight/apply; crates/gpu/src/wgsl/finish.wgsl::point_color',workingSpace='native extended linear sRGB / 2021 OkLab',rawLCh=raw,linearSRGB=linear)
(ROOT/'Tests/Fixtures/point-color-vectors.json').write_text(json.dumps(value,indent=2)+'\n')
print(f'{len(raw)} independent upstream LCh and {len(linear)} native RGB vectors')
