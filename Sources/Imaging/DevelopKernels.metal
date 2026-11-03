#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// CI images and geometric sampling carry premultiplied linear RGBA. Only
// per-pixel color math enters straight RGB, then premultiplies with unchanged
// coverage. No epsilon discards valid near-zero 16-bit alpha.
float4 straightColor(float4 s) {
    if (!isfinite(s.a) || s.a <= 0) return float4(0);
    float3 c = s.rgb / s.a;
    return float4(select(float3(0),c,isfinite(c)),s.a);
}

float4 harmonicSlope(float4 a, float4 b) {
    float4 sum = a + b;
    return select(float4(0), 2 * a * b / select(float4(1), sum, abs(sum) > 1e-12f), a * b > 0);
}
float4 fivePointCurve(float4 x, float4 p0, float4 p1, float4 p2, float4 p3, float4 p4) {
    float4 d0 = p1-p0, d1 = p2-p1, d2 = p3-p2, d3 = p4-p3;
    float4 m1 = harmonicSlope(d0,d1), m2 = harmonicSlope(d1,d2), m3 = harmonicSlope(d2,d3);
    x = clamp(x, 0.0f, 4.0f);
    float4 i = min(floor(x), 3.0f), t = x-i;
    float4 a = select(select(select(p0,p1,i>=1),p2,i>=2),p3,i>=3);
    float4 b = select(select(select(p1,p2,i>=1),p3,i>=2),p4,i>=3);
    float4 ma = select(select(select(d0,m1,i>=1),m2,i>=2),m3,i>=3);
    float4 mb = select(select(select(m1,m2,i>=1),m3,i>=2),d3,i>=3);
    return (2*t*t*t-3*t*t+1)*a + (t*t*t-2*t*t+t)*ma + (-2*t*t*t+3*t*t)*b + (t*t*t-t*t)*mb;
}
float4 toneEncode(float4 c) {
    c = max(c, 0.0f);
    return select(1.055f*pow(c, float4(1.0f/2.4f))-0.055f, 12.92f*c, c<=0.0031308f);
}
float4 toneDecode(float4 c) {
    return select(pow(max((c+0.055f)/1.055f,0.0f),float4(2.4f)), c/12.92f, c<=0.04045f);
}
float grainHashNoise(int i, int j, uint seed) {
    uint v = uint(i) * 0x8da6b343u ^ uint(j) * 0xd8163841u ^ seed * 0xcb1ab31fu;
    v ^= v >> 13;
    v *= 0x5bd1e995u;
    v ^= v >> 15;
    return float(v & 0xffff) / 32768.0f - 1.0f;
}
float grainNoise(float x, float y, uint seed) {
    float x0 = floor(x), y0 = floor(y);
    float fx = x - x0, fy = y - y0;
    int i = int(x0), j = int(y0);
    float u = fx * fx * (3.0f - 2.0f * fx);
    float vv = fy * fy * (3.0f - 2.0f * fy);
    float a0 = grainHashNoise(i, j, seed);
    float a1 = grainHashNoise(i + 1, j, seed);
    float b0 = grainHashNoise(i, j + 1, seed);
    float b1 = grainHashNoise(i + 1, j + 1, seed);
    float a = a0 + (a1 - a0) * u;
    float b = b0 + (b1 - b0) * u;
    return a + (b - a) * vv;
}
// Oklab matrices match PerceptualColor's Double reference (2021 revision).
float3 bwLab(float3 c) {
    float3 lms = float3(dot(c,float3(0.4122214708,0.5363325363,0.0514459929)),
        dot(c,float3(0.2119034982,0.6806995451,0.1073969566)),dot(c,float3(0.0883024619,0.2817188376,0.6299787005)));
    lms = sign(lms)*pow(abs(lms),float3(1.0f/3.0f));
    return float3(dot(lms,float3(0.2104542553,0.7936177850,-0.0040720468)),
        dot(lms,float3(1.9779984951,-2.4285922050,0.4505937099)),dot(lms,float3(0.0259040371,0.7827717662,-0.8086757660)));
}
float3 bwRGB(float3 lab) {
    float3 lms = float3(lab.x+0.3963377774f*lab.y+0.2158037573f*lab.z,
        lab.x-0.1055613458f*lab.y-0.0638541728f*lab.z,lab.x-0.0894841775f*lab.y-1.2914855480f*lab.z);
    lms = lms*lms*lms;
    return float3(dot(lms,float3(4.0767416621,-3.3077115913,0.2309699292)),
        dot(lms,float3(-1.2684380046,2.6097574011,-0.3413193965)),dot(lms,float3(-0.0041960863,-0.7034186147,1.7076147010)));
}
bool bwInGamut(float3 c) { return all(c >= -1e-7f) && all(c <= 1.0000001f); }
float3 bwGamutMap(float3 lab) {
    lab.x = clamp(lab.x,0.0f,1.0f);
    float3 result = bwRGB(lab);
    if (bwInGamut(result)) return clamp(result,0.0f,1.0f);
    float lo = 0, hi = 1;
    for (int i = 0; i < 16; ++i) {
        float mid = (lo+hi)/2;
        if (bwInGamut(bwRGB(float3(lab.x,lab.yz*mid)))) lo = mid; else hi = mid;
    }
    return clamp(bwRGB(float3(lab.x,lab.yz*lo)),0.0f,1.0f);
}
float bwHue(float3 c) {
    float hi = max(c.r,max(c.g,c.b)), lo = min(c.r,min(c.g,c.b)), d = hi-lo;
    if (d <= 0.000001f) return 0;
    float h = hi == c.r ? (c.g-c.b)/d : hi == c.g ? (c.b-c.r)/d+2 : (c.r-c.g)/d+4;
    return fmod(h*60+360,360.0f);
}
float bwBandShift(float hue, float4 first, float4 last) {
    float centers[8] = {0,30,60,120,180,240,270,300};
    float values[8] = {first.x,first.y,first.z,first.w,last.x,last.y,last.z,last.w};
    int i = 0;
    for (int j = 1; j < 8; ++j) { if (centers[j] <= hue) i = j; }
    int next = (i+1)%8;
    float t = smoothstep(centers[i],next == 0 ? 360 : centers[next],hue);
    return values[i]+(values[next]-values[i])*t;
}
// LightCraft 4f0b110 colorops.rs::band_weights / BwMix (MIT).
// Centres are converted from sRGB in Swift, never Rec.2020 RGB constants.
float bwPerceptualShift(float hue, float4 first, float4 last, float4 hues0, float4 hues1) {
    float centers[8] = {hues0.x,hues0.y,hues0.z,hues0.w,hues1.x,hues1.y,hues1.z,hues1.w};
    float values[8] = {first.x,first.y,first.z,first.w,last.x,last.y,last.z,last.w};
    for (int i = 0; i < 8; ++i) {
        int next = (i+1)%8;
        float span = fmod(centers[next]-centers[i]+2*M_PI_F,2*M_PI_F);
        float distance = fmod(hue-centers[i]+2*M_PI_F,2*M_PI_F);
        if (distance <= span) {
            float t = 0.5f-0.5f*cos(distance/span*M_PI_F);
            return values[i]+(values[next]-values[i])*t;
        }
    }
    return 0;
}
// PointK equations: LightCraft 4f0b110 colorops.rs / GPU finish.wgsl (MIT).
float pointWrap(float v) { return v-2*M_PI_F*floor((v+M_PI_F)/(2*M_PI_F)); }
float pointWeight(float3 lch,float4 a,float4 b,float4 c) {
    float wh = a.y < 0.02f ? 1.0f : (1-smoothstep(b.w/2,b.w,abs(pointWrap(lch.z-a.z))))*smoothstep(0.005f,0.025f,lch.y);
    return wh*(1-smoothstep(c.x/2,c.x,abs(lch.y-a.y)))*(1-smoothstep(c.y/2,c.y,abs(lch.x-a.x)));
}
float3 pointApply(float3 lch,float4 a,float4 b,float4 c) {
    if (a.w == 0 && all(b.xyz == float3(0))) return lch;
    float weight = pointWeight(lch,a,b,c);
    if (weight <= 0) return lch;
    float h = lch.z+weight*(b.z*pointWrap(lch.z-a.z)+a.w);
    float ch = max(0.0f,(lch.y+weight*b.z*(lch.y-a.y))*(1+weight*b.x));
    return float3(lch.x+weight*(b.z*(lch.x-a.x)+b.y),ch,h);
}
float3 pointMixerLab(float3 input,float4 hue0,float4 hue1,float4 sat0,float4 sat1,float4 lum0,float4 lum1) {
    float3 lab = bwLab(input);
    float chroma = length(lab.yz), light = lab.x;
    if (chroma > 1e-6f) {
        float hue = bwHue(toneEncode(float4(input,1)).rgb);
        float protect = smoothstep(0.0f,0.03f,chroma);
        float h = atan2(lab.z,lab.y)+bwBandShift(hue,hue0,hue1)*0.3f*M_PI_F/180*protect;
        float c = max(0.0f,chroma*(1+bwBandShift(hue,sat0,sat1)/100));
        lab = float3(light+bwBandShift(hue,lum0,lum1)*0.002f*protect*4*light*(1-light),c*cos(h),c*sin(h));
    }
    return lab;
}
// Raster exposure uses the same monotone 65-anchor response as the Double reference.
float rasterValue(thread const float4* p, int i) { i = clamp(i,0,64); return p[i/4][i%4]; }
float rasterHarmonic(float a,float b) { return a*b > 0 ? 2*a*b/(a+b) : 0; }
float rasterResponse(float input,thread const float4* p,float ev) {
    if (input < 0) return input*exp2(ev);
    if (input > 1) {
        float last = toneDecode(float4(rasterValue(p,64))).x;
        float slope = (last-toneDecode(float4(rasterValue(p,63))).x)/(1-toneDecode(float4(63.0f/64)).x);
        return last+(input-1)*slope;
    }
    float position = clamp(toneEncode(float4(input)).x,0.0f,1.0f)*64;
    int i = min(63,int(position)); float t = position-float(i);
    float a = rasterValue(p,i), b = rasterValue(p,i+1), d = b-a;
    float ma = i == 0 ? d : rasterHarmonic(a-rasterValue(p,i-1),d);
    float mb = i == 63 ? d : rasterHarmonic(d,rasterValue(p,i+2)-b);
    float y = (2*t*t*t-3*t*t+1)*a+(t*t*t-2*t*t+t)*ma
        +(-2*t*t*t+3*t*t)*b+(t*t*t-t*t)*mb;
    return toneDecode(float4(clamp(y,a,b))).x;
}
// LUT axes are the actual rounded UInt16 fixture anchors. Positive EV uses
// quadratic encoded-sRGB spacing to resolve near-black saturated colours.
float2 rasterColourAxis(float x, float power) {
    x = clamp(x, 0.0f, 1.0f);
    float i = min(63.0f, floor(pow(x, 1.0f/power)*64.0f));
    float a = floor(pow(i/64.0f,power)*65535.0f+0.5f)/65535.0f;
    float b = floor(pow((i+1)/64.0f,power)*65535.0f+0.5f)/65535.0f;
    if (x < a && i > 0) i -= 1;
    if (x > b && i < 63) i += 1;
    a = floor(pow(i/64.0f,power)*65535.0f+0.5f)/65535.0f;
    b = floor(pow((i+1)/64.0f,power)*65535.0f+0.5f)/65535.0f;
    return float2(i, clamp((x-a)/(b-a),0.0f,1.0f));
}
float3 rasterColourNode(coreimage::sampler table, float3 p) {
    // Bitmap rows run top to bottom; B is stored slowest, beginning at zero.
    return table.sample(table.transform(float2(p.x+65*p.y+0.5f,64.5f-p.z))).rgb;
}
float3 rasterColourSample(coreimage::sampler table, float3 encoded, float power) {
    float2 r = rasterColourAxis(encoded.r,power), g = rasterColourAxis(encoded.g,power), b = rasterColourAxis(encoded.b,power);
    float3 i = float3(r.x,g.x,b.x), f = float3(r.y,g.y,b.y);
    float3 a = mix(rasterColourNode(table,i),rasterColourNode(table,i+float3(1,0,0)),f.x);
    float3 c = mix(rasterColourNode(table,i+float3(0,1,0)),rasterColourNode(table,i+float3(1,1,0)),f.x);
    float3 d = mix(rasterColourNode(table,i+float3(0,0,1)),rasterColourNode(table,i+float3(1,0,1)),f.x);
    float3 e = mix(rasterColourNode(table,i+float3(0,1,1)),rasterColourNode(table,i+float3(1,1,1)),f.x);
    return mix(mix(a,c,f.y),mix(d,e,f.y),f.z);
}
extern "C" { namespace coreimage {
float4 pointColorInput(sample_t input,float4 hue0,float4 hue1,float4 sat0,float4 sat1,float4 lum0,float4 lum1) {
    float4 s = straightColor(input);
    if (s.a <= 0) return float4(0);
    return premultiply(float4(bwRGB(pointMixerLab(s.rgb,hue0,hue1,sat0,sat1,lum0,lum1)),s.a));
}
float4 pointColorRange(sample_t input,float4 p0,float4 p1,float4 p2,float4 p3,float4 p4,float4 p5,float4 p6,float4 p7,float4 p8,float4 p9,float4 p10,float4 p11,float4 p12,float4 p13,float4 p14,float4 p15,float4 p16,float4 p17,float4 p18,float4 p19,float4 p20,float4 p21,float4 p22,float4 p23,float selected) {
    float4 s = straightColor(input);
    if (s.a <= 0) return float4(0);
    float4 pts[24] = {p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23};
    float3 lab = bwLab(s.rgb);
    float3 lch = float3(lab.x,length(lab.yz),atan2(lab.z,lab.y));
    for (int i=0;i<int(selected);++i) lch = pointApply(lch,pts[i*3],pts[i*3+1],pts[i*3+2]);
    int k = int(selected)*3;
    float w = pointWeight(lch,pts[k],pts[k+1],pts[k+2]);
    return float4(float3(w*s.a),s.a);
}
float4 pointColorMix(sample_t input,float4 hue0,float4 hue1,float4 sat0,float4 sat1,float4 lum0,float4 lum1,float4 p0,float4 p1,float4 p2,float4 p3,float4 p4,float4 p5,float4 p6,float4 p7,float4 p8,float4 p9,float4 p10,float4 p11,float4 p12,float4 p13,float4 p14,float4 p15,float4 p16,float4 p17,float4 p18,float4 p19,float4 p20,float4 p21,float4 p22,float4 p23,float count,float saturation,float vibrance,
    float4 shadowTone,float4 middleTone,float4 highTone,float4 globalTone,float blending,float balance) {
    float4 s = straightColor(input);
    if (s.a <= 0) return float4(0);
    float4 pts[24] = {p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15,p16,p17,p18,p19,p20,p21,p22,p23};
    float3 lab = pointMixerLab(s.rgb,hue0,hue1,sat0,sat1,lum0,lum1);
    float3 lch = float3(lab.x,length(lab.yz),atan2(lab.z,lab.y));
    for (int i=0;i<int(count);++i) lch = pointApply(lch,pts[i*3],pts[i*3+1],pts[i*3+2]);
    // Preserve native vibrance's original-chroma envelope even when HSL or
    // point colours change C; an unrelated range must not alter other colours.
    float originalChroma = length(bwLab(s.rgb).yz);
    lch.y = max(0.0f,lch.y*saturation*(1+vibrance/100*(1-smoothstep(0.03f,0.25f,originalChroma))));
    if (saturation == 0) lch.y = 0;
    float3 value = float3(lch.x,lch.y*cos(lch.z),lch.y*sin(lch.z));
    float light = clamp(value.x,0.0f,1.0f), position = clamp(light+balance*0.0025f,0.0f,1.0f);
    float width = 0.08f+blending*0.002f;
    float shadow = 1-smoothstep(0.33f-width,0.33f+width,position);
    float highlight = smoothstep(0.67f-width,0.67f+width,position);
    float weights[4] = {shadow,max(0.0f,1-shadow-highlight),highlight,1};
    float4 tones[4] = {shadowTone,middleTone,highTone,globalTone};
    float envelope = 4*light*(1-light);
    for (int i=0;i<4;++i) { value.yz += tones[i].xy*weights[i]*envelope; value.x += tones[i].z*weights[i]*envelope; }
    return premultiply(float4(bwGamutMap(value),s.a));
}
float4 noiseMoments(sample_t input) {
    float4 s = straightColor(input);
    float l = log2(max(1e-6f,dot(s.rgb,float3(0.2126,0.7152,0.0722)))/0.18f);
    return float4(l*s.a,l*l*s.a,0,s.a);
}
float4 noiseCoefficients(sample_t input, sample_t stats, float epsilon) {
    if (stats.a <= 0) return float4(0);
    float mean = stats.r/stats.a;
    float variance = max(0.0f,stats.g/stats.a-mean*mean);
    float a = variance/(variance+epsilon);
    return float4(a*input.a,mean*(1-a)*input.a,0,input.a);
}
float4 generalLumaDenoise(sample_t input, sample_t coefficients, float blend) {
    float4 s = straightColor(input);
    if (s.a <= 0 || coefficients.a <= 0) return float4(0);
    float l = log2(max(1e-6f,dot(s.rgb,float3(0.2126,0.7152,0.0722)))/0.18f);
    float filtered = (coefficients.r*l+coefficients.g)/coefficients.a;
    float gain = exp2(clamp((filtered-l)*blend,-2.0f,2.0f));
    return float4(s.rgb*gain*s.a,s.a);
}
// LightCraft's chromaticity/luminance separation, with a local joint bilateral
// range term to protect luminance AND isoluminant colour edges. No RGB clipping.
float4 generalChromaDenoise(sampler input, float4 extent, float sigma, float blend, float range, destination dest) {
    float2 center = dest.coord();
    float4 s = straightColor(input.sample(input.transform(center)));
    if (s.a <= 0) return float4(0);
    float3 weights = float3(0.2126,0.7152,0.0722);
    float y = dot(s.rgb,weights), l = log2(max(1e-6f,y)/0.18f);
    float3 c = (s.rgb-y)/max(0.05f,y), sum = float3(0);
    float mass = 0; int radius = int(ceil(2*sigma));
    for (int dy = -4; dy <= 4; ++dy) { for (int dx = -4; dx <= 4; ++dx) {
        if (abs(dx) > radius || abs(dy) > radius) continue;
        float2 p = clamp(center+float2(dx,dy),extent.xy+0.5f,extent.xy+extent.zw-0.5f);
        float4 v = straightColor(input.sample(input.transform(p)));
        if (v.a <= 0) continue;
        float vy = dot(v.rgb,weights), vl = log2(max(1e-6f,vy)/0.18f);
        float3 vc = (v.rgb-vy)/max(0.05f,vy), delta = vc-c;
        float spatial = float(dx*dx+dy*dy)/(sigma*sigma), ld = (vl-l)/0.5f;
        float w = exp(-0.5f*(spatial+ld*ld+dot(delta,delta)/(range*range)))*v.a;
        sum += vc*w; mass += w;
    } }
    if (mass <= 0) return float4(s.rgb*s.a,s.a);
    float3 out = s.rgb+(sum/mass-c)*(blend*max(0.05f,y));
    out += y-dot(out,weights);
    return float4(out*s.a,s.a);
}
// General decoded-image detail. LightCraft f34c7a8 log-luminance / masking,
// adapted to linear sRGB, alpha-weighted exact Gaussian and bounded EV gain.
float4 detailGaussian(sampler input, float4 extent, float2 axis, float sigma, float bounds, destination dest) {
    float4 sum = float4(0); float weight = 0; float low = 1e6f, high = -1e6f;
    int radius = int(ceil(3*sigma));
    for (int j = -11; j <= 11; ++j) {
        if (abs(j) > radius) continue;
        float w = exp(-float(j*j)/(2*sigma*sigma));
        float2 p = clamp(dest.coord()+axis*float(j),extent.xy+0.5f,extent.xy+extent.zw-0.5f);
        float4 v = input.sample(input.transform(p));
        sum += v*w; weight += w;
        if (v.a > 0) { low = min(low,v.y); high = max(high,v.z); }
    }
    float4 result = sum/weight;
    if (bounds > 0) { result.y = low; result.z = high; }
    return result;
}
float4 detailLog(sample_t input) {
    float4 s = straightColor(input);
    float l = log2(max(1e-6f,dot(s.rgb,float3(0.2126,0.7152,0.0722)))/0.18f);
    return float4(l*s.a,l,l,s.a);
}
float4 generalSharpen(sample_t input, sample_t base, float amount, float protection, float blend) {
    float4 s = straightColor(input);
    if (s.a <= 0 || base.a <= 0) return float4(0);
    float l = log2(max(1e-6f,dot(s.rgb,float3(0.2126,0.7152,0.0722)))/0.18f);
    float d = l-base.r/base.a;
    float mask = protection == 0 ? 1 : smoothstep(protection*0.25f,protection*0.25f+0.15f,abs(d));
    float edge = (1-smoothstep(0.5f,2.0f,abs(d)))*(1-smoothstep(1.0f,3.0f,base.z-base.y));
    float delta = 0.25f*tanh(amount*1.3f*d*mask*edge*blend/0.25f);
    return float4(s.rgb*exp2(delta)*s.a,s.a);
}
float4 manualPerspective(sampler input, float3 rowX, float3 rowY, float3 rowW, float4 extent, destination dest) {
    float3 p = float3(dest.coord(), 1);
    float w = dot(rowW, p);
    // Outside the valid projective half-plane samples transparent black.
    if (!isfinite(w) || w <= 1e-9f) return float4(0);
    float2 q = float2(dot(rowX, p), dot(rowY, p)) / w;
    // CI's warp sampler extends the edge. Explicitly reject missing pixels;
    // neither a clamped coordinate nor a repeated edge may fill this region.
    if (any(q < extent.xy) || any(q >= extent.xy+extent.zw)) return float4(0);
    // Explicit float weights avoid the texture unit's quantized interpolation
    // weights on high-contrast grid edges. Sample at source pixel centres.
    float2 base = floor(q-0.5f)+0.5f, f = q-base;
    float4 a = input.sample(input.transform(base));
    float4 b = input.sample(input.transform(base+float2(1,0)));
    float4 c = input.sample(input.transform(base+float2(0,1)));
    float4 d = input.sample(input.transform(base+float2(1,1)));
    return mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
}
// Active black/white mixer only. Zero controls keep the existing color-cube path.
float4 blackWhiteMix(sample_t s, float4 mixer0, float4 mixer1, float4 hue0, float4 hue1,
    float4 sat0, float4 sat1, float4 hsl0, float4 hsl1, float4 hues0, float4 hues1, float saturation, float vibrance,
    float4 shadowTone, float4 middleTone, float4 highTone, float4 globalTone, float blending, float balance) {
    float3 input = straightColor(s).rgb;
    float3 original = bwLab(input);
    float chroma = length(original.yz), originalL = original.x;
    float hue = bwHue(toneEncode(float4(input,1)).rgb);
    float protection = smoothstep(0.0f,0.03f,chroma), envelope = 4*originalL*(1-originalL);
    float lightness = originalL;
    if (chroma > 1e-6f) lightness += bwBandShift(hue,hsl0,hsl1)*0.002f*protection*envelope;
    float changedChroma = max(0.0f,chroma*(1+bwBandShift(hue,sat0,sat1)/100)*saturation
        *(1+vibrance/100*(1-smoothstep(0.03f,0.25f,chroma))));
    float changedHue = atan2(original.z,original.y)+bwBandShift(hue,hue0,hue1)*0.3f*M_PI_F/180*protection;
    if (chroma > 1e-6f && changedChroma > 1e-6f)
        lightness = max(0.0f,lightness+bwPerceptualShift(changedHue,mixer0,mixer1,hues0,hues1)/100*min(changedChroma/0.2f,1.0f)*0.25f);
    float3 value = float3(lightness,0,0);
    float light = clamp(lightness,0.0f,1.0f), position = clamp(light+balance*0.0025f,0.0f,1.0f);
    float width = 0.08f+blending*0.002f;
    float shadow = 1-smoothstep(0.33f-width,0.33f+width,position);
    float highlight = smoothstep(0.67f-width,0.67f+width,position);
    float weights[4] = {shadow,max(0.0f,1-shadow-highlight),highlight,1};
    float4 tones[4] = {shadowTone,middleTone,highTone,globalTone};
    float gradeEnvelope = 4*light*(1-light);
    for (int i = 0; i < 4; ++i) {
        value.yz += tones[i].xy*weights[i]*gradeEnvelope;
        value.x += tones[i].z*weights[i]*gradeEnvelope;
    }
    return premultiply(float4(bwGamutMap(value),s.a));
}
// Each packed point is (input, output, derivative, unused), prepared by TonalPipeline.
// Independent calibrated operator; RGB hue is preserved in linear ROMM primaries.
float4 rasterExposure(sample_t input, float4 p0, float4 p1, float4 p2, float4 p3, float4 p4, float4 p5, float4 p6, float4 p7, float4 p8, float4 p9, float4 p10, float4 p11, float4 p12, float4 p13, float4 p14, float4 p15, float4 p16, float ev) {
    float4 s = straightColor(input);
    if (s.a <= 0) return float4(0);
    float3 c = float3(dot(s.rgb,float3(0.5292907577680172,0.33015660364785177,0.14055263858413108)),
        dot(s.rgb,float3(0.09836164805996374,0.8734849381186465,0.028153413821389802)),
        dot(s.rgb,float3(0.016866088436003183,0.11765576165553973,0.8654781499084571)));
    float4 p[17] = { p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16 };
    float lo = min(c.r,min(c.g,c.b)), hi = max(c.r,max(c.g,c.b));
    float low = rasterResponse(lo,p,ev), high = rasterResponse(hi,p,ev);
    c = hi > lo ? float3(low)+(c-lo)*((high-low)/(hi-lo)) : float3(low);
    float3 rgb = float3(dot(c,float3(2.0343104306914266,-0.7276094363341301,-0.30670099435729664)),
        dot(c,float3(-0.22880499207676658,1.2317141502386277,-0.00290915816186133)),
        dot(c,float3(-0.008539365225714066,-0.1532636513148021,1.1618030165405162)));
    return premultiply(float4(rgb,s.a));
}
float4 rasterExposureColour(sampler photo, sampler base, sampler low, sampler high, float2 powers, float weight) {
    float4 s = straightColor(photo.sample(photo.coord()));
    if (s.a <= 0) return float4(0);
    float3 e = toneEncode(float4(s.rgb,1)).rgb;
    float3 a = rasterColourSample(low,e,powers.x);
    float3 delta = weight == 0 ? a : mix(a,rasterColourSample(high,e,powers.y),weight);
    return float4(base.sample(base.coord()).rgb+delta*s.a,s.a);
}
float4 toneCurves(sample_t s, float4 p0, float4 p1, float4 p2, float4 p3, float4 p4, float4 p5, float4 p6, float4 p7, float4 p8, float4 p9, float4 p10, float4 p11, float4 p12, float4 p13, float4 p14, float4 p15, float pointCount, float channel) {
    float4 points[16] = { p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15 };
    float3 c = straightColor(s).rgb;
    int component = max(0, int(channel)-1);
    float source = channel == 0 ? dot(c, float3(0.2126,0.7152,0.0722)) : c[component];
    float x = clamp(toneEncode(float4(source)).x, 0.0f, 1.0f);
    int segment = 0;
    for (int j = 1; j < int(pointCount)-1; ++j) { if (points[j].x <= x) segment = j; }
    float4 a = points[segment], b = points[segment+1];
    float h = b.x-a.x, t = (x-a.x)/h;
    float y = (2*t*t*t-3*t*t+1)*a.y + (t*t*t-2*t*t+t)*h*a.z
        + (-2*t*t*t+3*t*t)*b.y + (t*t*t-t*t)*h*b.z;
    float target = toneDecode(float4(clamp(y,min(a.y,b.y),max(a.y,b.y)))).x;
    if (channel == 0) c = source > 1e-8f ? c * (target/source) : float3(target);
    else c[component] = target;
    return premultiply(float4(c,s.a));
}
float4 zoneExposure(sample_t s, sample_t base, float4 gains, float last) {
    float ev = base.r;
    float output = fivePointCurve(float4((ev+8)/2),float4(-8+gains.x),float4(-6+gains.y),float4(-4+gains.z),float4(-2+gains.w),float4(last)).x;
    // Clamping between ev±1 preserves monotonic output while bounding interpolated gain.
    float gain = ev <= -8 ? gains.x : ev >= 0 ? last : clamp(output-ev,-1.0f,1.0f);
    return float4(s.rgb*exp2(gain),s.a);
}
float4 logLuminance(sample_t s) {
    float y = dot(straightColor(s).rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(float3(log2(max(y, 0.000015258789))), 1);
}
float4 linearLuminance(sample_t s) {
    float y = dot(straightColor(s).rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(float3(y), 1);
}
float4 guideMoments(sample_t i, sample_t p) {
    return float4(i.r, p.r, i.r * i.r, 1);
}
float4 guideProduct(sample_t i, sample_t p) { return float4(float3(i.r * p.r), 1); }
// Alpha-weighted analysis only for images with transparency. Scalar statistics
// never let invisible RGB or a transparent black border count as photo evidence.
float4 guideWeight(sample_t value, sample_t coverage) {
    return float4(value.rgb * coverage.a, coverage.a);
}
float4 guideUnweight(sample_t value) {
    return float4(value.a > 0 ? value.rgb / value.a : float3(0), 1);
}
float4 alphaCoverage(sample_t value) { return float4(float3(value.a),1); }
float4 guideCoefficients(sample_t means, sample_t product, float epsilon) {
    float variance = max(0.0f, means.b - means.r * means.r);
    float a = (product.r - means.r * means.g) / (variance + epsilon);
    return float4(a, means.g - a * means.r, 0, 1);
}
float4 guideReconstruct(sample_t i, sample_t coefficients) {
    return float4(float3(coefficients.r * i.r + coefficients.g), 1);
}
float4 darkChannel(sample_t s, float3 airlight) {
    if (s.a <= 0) return float4(1);
    float3 c = max(straightColor(s).rgb, 0.0f) / airlight;
    return float4(float3(min(c.r, min(c.g, c.b))), 1);
}
float4 transmission(sample_t dark) { return float4(float3(1.0f - 0.95f * dark.r), 1); }
float4 removeHaze(sample_t s, sample_t transmission, float3 airlight, float amount) {
    float3 c = straightColor(s).rgb;
    float t = clamp(transmission.r, 0.2f, 1.0f);
    // Slider changes optical depth. Negative values synthesize haze with the same model.
    float adjusted = pow(t, abs(amount));
    float3 result = amount > 0 ? (c - airlight) / adjusted + airlight
                              : c * adjusted + airlight * (1.0f - adjusted);
    return premultiply(float4(max(result, 0.0f), s.a));
}
float4 toneEqualize(sample_t s, sample_t base, float4 controls) {
    float x = base.r;
    // Ordered output knots stay monotone for every allowed combination (±100).
    float d0 = controls.w * 0.008f;
    float d1 = controls.w * 0.012f;
    float d2 = controls.y * 0.016f;
    float d3 = controls.x * 0.012f;
    float d4 = controls.z * 0.006f;
    float delta = x < -8 ? mix(d0, d1, clamp((x + 16) / 8, 0.0f, 1.0f))
                : x < -5 ? mix(d1, d2, (x + 8) / 3)
                : x < -2 ? mix(d2, d3, (x + 5) / 3)
                : mix(d3, d4, clamp((x + 2) / 2, 0.0f, 1.0f));
    return float4(s.rgb * exp2(delta), s.a);
}
float4 detailEnhance(sample_t s, sample_t guide, sample_t base, float amount) {
    float residual = guide.r - base.r;
    // Suppress tiny residuals and cap gain to avoid boosting noise and ringing without bound.
    float detail = tanh(residual) * smoothstep(0.025f, 0.10f, abs(residual));
    return float4(s.rgb * exp2(detail * amount * 0.8f), s.a);
}
// Masks contain coverage data, not gamma-encoded display colors.
float4 maskShape(float4 extent, float4 points, float4 shape, float kind, destination dest) {
    float2 p = dest.coord() - extent.xy;
    float2 a = points.xy * extent.zw;
    float m;
    if (kind < 0.5f) {
        float2 d = (points.zw - points.xy) * extent.zw;
        m = clamp(dot(p - a, d) / max(dot(d, d), 0.000001f), 0.0f, 1.0f);
    } else {
        float2 d = p - a;
        float cs = cos(shape.z), sn = sin(shape.z);
        float2 q = float2(cs * d.x + sn * d.y, -sn * d.x + cs * d.y) / max(shape.xy * extent.zw, float2(0.001f));
        float r = length(q);
        m = shape.w <= 0 ? (r <= 1 ? 1.0f : 0.0f) : 1 - smoothstep(1 - shape.w, 1.0f, r);
    }
    return float4(float3(m), 1);
}
float4 maskCombine(sample_t a, sample_t b, float operation, float inverted, float amount) {
    float x = clamp(a.r, 0.0f, 1.0f), y = clamp(b.r, 0.0f, 1.0f);
    if (inverted > 0) y = 1 - y;
    float m = operation < 0.5f ? y : operation < 1.5f ? max(x, y) : operation < 2.5f ? x * (1 - y) : x * y;
    return float4(float3(m * amount), 1);
}
// Oklab transform matches the coefficients in PerceptualColor.swift.
float3 maskLab(float3 c) {
    float l = pow(max(0.0f, dot(c, float3(0.4122214708, 0.5363325363, 0.0514459929))), 1.0f/3);
    float m = pow(max(0.0f, dot(c, float3(0.2119034982, 0.6806995451, 0.1073969566))), 1.0f/3);
    float s = pow(max(0.0f, dot(c, float3(0.0883024619, 0.2817188376, 0.6299787005))), 1.0f/3);
    return float3(0.2104542553*l+0.7936177850*m-0.0040720468*s,
                  1.9779984951*l-2.4285922050*m+0.4505937099*s,
                  0.0259040371*l+0.7827717662*m-0.8086757660*s);
}
float4 maskGuide(sample_t s) {
    return float4(float3(maskLab(max(straightColor(s).rgb, 0.0f)).x), 1);
}
float4 maskHardness(sample_t s, float hardness) {
    float value = clamp(s.r, 0.0f, 1.0f);
    if (hardness != 0 && value > 0 && value < 1) {
        float exponent = exp2(hardness * 2);
        float a = pow(value, exponent), b = pow(1-value, exponent);
        value = a / (a+b);
    }
    return float4(float3(value), 1);
}
float4 maskRange(sample_t sample, float4 params, float3 color, float kind) {
    float3 c = clamp(straightColor(sample).rgb, 0.0f, 1.0f);
    float coverage;
    if (kind < 0.5f) {
        float value = maskLab(c).x;
        float lo = params.x, hi = params.y, width = params.z;
        float low = lo <= 0 ? 1 : width <= 0 ? step(lo, value) : smoothstep(lo - width, lo, value);
        float high = hi >= 1 ? 1 : width <= 0 ? step(value, hi) : 1 - smoothstep(hi, hi + width, value);
        coverage = low * high;
    } else {
        // Lightcraft color range: a and b at full weight, lightness at half
        // (0.25 on the squared L term). Both sides are linear sRGB, then Oklab.
        float3 delta = maskLab(c) - maskLab(color);
        float distance = length(float3(delta.x * 0.5f, delta.y, delta.z));
        coverage = params.y <= 0 ? step(distance, params.x) : 1 - smoothstep(params.x, params.x + params.y, distance);
    }
    return float4(float3(coverage), 1);
}
float4 maskOverlay(sample_t mask, float3 color) {
    float alpha = clamp(mask.r, 0.0f, 1.0f) * 0.45f;
    return float4(color * alpha, alpha);
}
// Display-only mask views. style: 0 color, 1 color on gray, 2 photo on black, 3 photo on white, 4 coverage.
// Gray uses the same Rec.709 weights as logLuminance. None of this enters develop or export.
float4 maskView(sample_t photo, sample_t coverage, float3 tint, float3 mat, float style) {
    float3 p = clamp(straightColor(photo).rgb, 0.0f, 1.0f);
    float m = clamp(coverage.r, 0.0f, 1.0f);
    float3 result;
    if (style < 0.5f) {
        float a = m * 0.45f;
        result = tint * a + p * (1.0f - a);
    } else if (style < 1.5f) {
        float y = dot(p, float3(0.2126, 0.7152, 0.0722));
        float a = m * 0.45f;
        result = tint * a + float3(y) * (1.0f - a);
    } else if (style < 3.5f) {
        result = mix(mat, p, m);
    } else {
        result = float3(m);
    }
    return float4(result, 1.0f);
}

// Post-crop creative vignette. Same mapping as lightcraft finish.rs Vig / vignette()
// (commit 5436951). Rec.709 luma because these pixels are linear sRGB.
// Attribution: docs/references/lightcraft-LICENSE.txt.
float4 creativeVignette(sample_t s, float4 extent, float4 vigA, float4 vigB, destination dest) {
    float3 c = straightColor(s).rgb;
    float amount = vigA.x, start = vigA.y, width = vigA.z, power = vigA.w;
    float aspectMix = vigB.x, highlights = vigB.y, style = vigB.z;
    float2 size = max(extent.zw, float2(1e-6));
    float aspect = size.x / size.y;
    float2 p = dest.coord() - extent.xy;
    float u = p.x / size.x * 2.0 - 1.0;
    float vv = p.y / size.y * 2.0 - 1.0;
    float sx = 1.0 + (aspect - 1.0) * aspectMix;
    float sy = 1.0 + (1.0 / aspect - 1.0) * aspectMix;
    float n = max(sx, sy);
    float ax = abs(u * max(sx, 1.0) / n);
    float ay = abs(vv * max(sy, 1.0) / n);
    float dist = pow(pow(ax, power) + pow(ay, power), 1.0 / power);
    float t = smoothstep(start, start + width, dist);
    if (t <= 0.0) return s;
    if (amount < 0.0) {
        float f = 1.0 + amount * t;
        if (style < 0.5) {
            float lum = clamp(dot(c, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
            f += (1.0 - f) * highlights * smoothstep(0.4, 1.0, lum);
        }
        if (style > 1.5) c = c * (1.0 - (-amount) * t);
        else c = c * f;
    } else {
        c = c + (1.0 - c) * amount * t * 0.85;
    }
    return premultiply(float4(c, s.a));
}

// Post-crop film grain. Same hash, value noise and encoded-domain mix as
// lightcraft finish.rs GRAIN_HASH / grain_noise (commit 5436951).
// Attribution: docs/references/lightcraft-LICENSE.txt.
float4 filmGrain(sample_t s, float4 extent, float4 params, float4 seedParts, destination dest) {
    float3 c = straightColor(s).rgb;
    float amount = params.x, cell = params.y, rough = params.z;
    uint seed = uint(seedParts.x) + (uint(seedParts.y) << 16);
    float2 size = max(extent.zw, float2(1e-6));
    float longEdge = max(size.x, size.y);
    float2 p = dest.coord() - extent.xy;
    float gx = p.x / longEdge, gy = p.y / longEdge;
    float sc = longEdge / max(cell, 1e-6);
    float g = grainNoise(gx * sc, gy * sc, seed);
    g = g * (1.0f - rough * 0.5f) + grainNoise(gx * sc * 2.3f, gy * sc * 2.3f, seed ^ 0x55u) * rough * 0.7f;
    float3 e = toneEncode(float4(c, 0.0f)).xyz;
    float lum = 0.2126f * e.x + 0.7152f * e.y + 0.0722f * e.z;
    float k = amount * g * (0.35f + 2.6f * lum * (1.0f - lum));
    c = toneDecode(float4(e + float3(k), 0.0f)).xyz;
    return premultiply(float4(c, s.a));
}
// Linear thresholds sit halfway between the 8-bit sRGB codes 254/255 and 0/1 of the preview, matching the histogram's end bins.
float4 clipWarning(sample_t s, float3 shadow, float3 highlight, float showShadow, float showHighlight) {
    if (s.a <= 0) return float4(0);
    float3 c = straightColor(s).rgb;
    if (showHighlight > 0.5f && max(c.r, max(c.g, c.b)) > 0.99555f) return premultiply(float4(highlight, s.a));
    if (showShadow > 0.5f && min(c.r, min(c.g, c.b)) < 0.000152f) return premultiply(float4(shadow, s.a));
    return s;
}
} }
