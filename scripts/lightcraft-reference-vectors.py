#!/usr/bin/env python3
"""Independent Double formula transcription of pinned LightCraft Rust (MIT).
Usage: python3 scripts/lightcraft-reference-vectors.py LIGHTCRAFT_CHECKOUT OUTPUT
No Swift/Metal code or lightcraft application is executed. No dependencies.
Attribution: docs/references/lightcraft-LICENSE.txt.
"""
import colorsys
import hashlib
import json
import math
import pathlib
import struct
import subprocess
import sys

COMMIT = '4f0b110bcbd2e350c6d97b47f1d824c2222295c4'
checkout, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
paths = ['crates/pipeline/src/colorops.rs', 'crates/pipeline/src/transform.rs',
         'crates/color/src/spline.rs', 'crates/color/src/perceptual.rs',
         'crates/color/src/lib.rs', 'crates/develop/src/settings.rs', 'LICENSE-MIT']
sources = {p: hashlib.sha256(subprocess.check_output(['git', '-C', str(checkout), 'show', f'{COMMIT}:{p}'])).hexdigest() for p in paths}

def mul(a, b):
    return [[sum(a[i][k]*b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]

def apply(a, v):
    return [sum(x*y for x, y in zip(row, v)) for row in a]

def inverse(m):
    a,b,c,d,e,f,g,h,i = sum(m, [])
    det = a*(e*i-f*h)+b*(f*g-d*i)+c*(d*h-e*g)
    return [[v/det for v in row] for row in [[e*i-f*h,c*h-b*i,b*f-c*e], [f*g-d*i,a*i-c*g,c*d-a*f], [d*h-e*g,b*g-a*h,a*e-b*d]]]

def rgb_xyz(primaries):
    cols = [[x/y, 1, (1-x-y)/y] for x,y in primaries]
    m = [list(row) for row in zip(*cols)]
    s = apply(inverse(m), [0.3127/0.3290,1,(1-0.3127-0.3290)/0.3290])
    return [[m[r][c]*s[c] for c in range(3)] for r in range(3)]

# Upstream's XYZ-based Oklab and primaries are distinct from our 2021 sRGB
# matrices. Preserve both references; do not copy Rec.2020 coefficients to sRGB.
xyz_lms = [[.8189330101,.3618667424,-.1288597137], [.0329845436,.9293118715,.0361456387], [.0482003018,.2643662691,.6338517070]]
lms_lab = [[.2104542553,.7936177850,-.0040720468], [1.9779984951,-2.4285922050,.4505937099], [.0259040371,.7827717662,-.8086757660]]
srgb_xyz = rgb_xyz([(.64,.33),(.30,.60),(.15,.06)])
rec_xyz = rgb_xyz([(.708,.292),(.170,.797),(.131,.046)])
modern_lms = [[.4122214708,.5363325363,.0514459929], [.2119034982,.6806995451,.1073969566], [.0883024619,.2817188376,.6299787005]]

def decode(v): return v/12.92 if v <= .04045 else ((v+.055)/1.055)**2.4

def lab(rgb, modern):
    lms = apply(modern_lms if modern else mul(xyz_lms, rec_xyz), rgb)
    return apply(lms_lab, [math.cbrt(x) for x in lms])

centres = [0,30,60,120,180,225,270,315]  # settings.rs::MIXER_HUES

def band_hues(modern):
    result = []
    for h in centres:
        rgb = [decode(x) for x in colorsys.hsv_to_rgb(h/360,1,1)]
        if not modern: rgb = apply(mul(inverse(rec_xyz), srgb_xyz), rgb)
        _,a,b = lab(rgb, modern)
        result.append(math.atan2(b,a))
    return result

def weights(h, hues):
    w = [0.0]*8
    for i in range(8):
        span = (hues[(i+1)%8]-hues[i]) % math.tau
        distance = (h-hues[i]) % math.tau
        if distance <= span:
            t = .5-.5*math.cos(distance/span*math.pi)
            w[i], w[(i+1)%8] = 1-t, t
            break
    return w

controls = [1,-1,.8,-.8,.6,-.6,.4,-.4]
bw = []
for deg in [-179,-120,-60,0,29,60,90,120,179]:
    for c in [.0001,.05,.2,.4]:
        h = math.radians(deg)
        row = {'h':h,'c':c}
        for modern, key in [(False,'upstream'),(True,'linearSRGB2021')]:
            w = weights(h,band_hues(modern))
            row[key] = {'weights':w,'l':max(0,.6+sum(a*b for a,b in zip(w,controls))*min(c/.2,1)*.25)}
        bw.append(row)

def manual(horizontal, vertical, aspect):
    sy,cy = math.sin(horizontal*.005),math.cos(horizontal*.005)
    sx,cx = math.sin(-vertical*.005),math.cos(-vertical*.005)
    r = mul([[cy,0,sy],[0,1,0],[-sy,0,cy]],[[1,0,0],[0,cx,-sx],[0,sx,cx]])
    h = mul([[1.5,0,0],[0,1.5,0],[0,0,1]],mul(r,[[1/1.5,0,0],[0,1/1.5,0],[0,0,1]]))
    origin = apply(h,[0,0,1]); ox,oy = origin[0]/origin[2],origin[1]/origin[2]
    h = mul([[1,0,-ox],[0,1,-oy],[0,0,1]],h)
    px,py = apply(h,[1e-4,0,1]),apply(h,[0,1e-4,1])
    det = abs((px[0]*py[1]-px[1]*py[0])/(px[2]*py[2]*1e-8))
    scale = 1/math.sqrt(det) if det > 1e-12 else 1
    k = 2**(aspect/200)
    return sum(mul([[scale/k,0,0],[0,scale*k,0],[0,0,1]],h),[])

# spline.rs::MonotoneCurve: arithmetic slopes + Fritsch-Carlson limiter;
# compare directly and through the actual 1024-entry f32 LUT convention.
def spline(points):
    xs,ys = zip(*points)
    d = [(ys[i+1]-ys[i])/(xs[i+1]-xs[i]) for i in range(len(xs)-1)]
    m = [d[0]]+[0 if d[i-1]*d[i]<=0 else (d[i-1]+d[i])/2 for i in range(1,len(d))]+[d[-1]]
    for i,v in enumerate(d):
        if v == 0: m[i]=m[i+1]=0; continue
        a,b = m[i]/v,m[i+1]/v
        if a*a+b*b > 9:
            t = 3/math.sqrt(a*a+b*b)
            m[i],m[i+1] = t*a*v,t*b*v
    def evaluate(x):
        if x <= xs[0]: return ys[0]
        if x >= xs[-1]: return ys[-1]
        i = max(i for i in range(len(xs)-1) if xs[i] <= x)
        h = xs[i+1]-xs[i]; t = (x-xs[i])/h
        return (2*t**3-3*t*t+1)*ys[i]+(t**3-2*t*t+t)*h*m[i]+(-2*t**3+3*t*t)*ys[i+1]+(t**3-t*t)*h*m[i+1]
    return evaluate

def f32(v): return struct.unpack('f',struct.pack('f',v))[0]
curves=[]
for points in [[[0,0],[.1,.4],[.6,.45],[1,1]],[[0,0],[.2,.7],[.65,.25],[1,1]],[[0,0],[.4,.5],[.6,.5],[1,1]]]:
    evaluate = spline(points); lut = [f32(evaluate(i/1023)) for i in range(1024)]
    values=[]
    for i in range(1001):
        f = f32(f32(i/1000)*1023); j = min(int(f),1022); t=f32(f-j)
        values.append(f32(lut[j]+f32(f32(lut[j+1]-lut[j])*t)))
    curves.append({'points':points,'direct':[evaluate(i/1000) for i in range(1001)],'lut':values})
params = [[0,0,0],[65,-45,18],[-100,100,-100],[100,100,100],[0,-50,0],[0,0,100]]
rgb_bw=[]
for rgb in [[0,0,0],[1,1,1],[.4,.4,.4],[.8,.2,.1],[.1,.7,.4],[.15,.1,.9],[.01,.02,.04],[.2,.20001,.2],[1.4,.4,.2]]:
    l,a,b = lab(rgb,True); c=math.hypot(a,b); h=math.atan2(b,a)
    mix=sum(x*y for x,y in zip(weights(h,band_hues(True)),controls))
    target=max(0,l+mix*min(c/.2,1)*.25) if c>1e-6 else l
    rgb_bw.append(dict(rgb=rgb,lightness=target,linear=[min(1,max(0,target**3*k)) for k in [1.0000000000,1.0000000000,1.0000000000]]))
result = dict(commit=COMMIT,commitDate='2026-10-18T11:16:37+08:00',sourceSHA256=sources,
    method='Independent Python Double transcription of upstream source formulas; no lightcraft app, Swift or Metal execution',
    bandHues=band_hues(False),linearSRGB2021BandHues=band_hues(True),bw=bw,rgbBW=rgb_bw,
    perspective=[dict(parameters=p,matrix=manual(*p)) for p in params],curves=curves)
output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(f'Wrote {output}: {len(bw)} BW vectors, {len(params)} matrices, {len(curves)} curves')
