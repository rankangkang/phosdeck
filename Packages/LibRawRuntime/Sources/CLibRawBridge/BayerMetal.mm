#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstring>
#include <cstdint>

// The application's default metallib uses the Core Image kernel ABI. Compile
// this compute pipeline once per process, independently of that library.
static const char *bayerSource = R"metal(
#include <metal_stdlib>
using namespace metal;

// LibRaw supplies black-subtracted, white-balanced samples in sensor orientation.
// Keep the measured CFA component at every site. Estimate green along the
// smoother axis, then interpolate red/blue differences relative to green.
static uint bayerChannel(uint2 pos, uint filters) {
    return (filters >> (2 * (2 * (pos.y & 7) + (pos.x & 1)))) & 3;
}

kernel void phosdeckBayerGreen(device const ushort4 *mosaic [[buffer(0)]],
                               device ushort *green [[buffer(1)]],
                               constant uint *params [[buffer(2)]],
                               uint2 p [[thread_position_in_grid]]) {
    uint w = params[0], h = params[1], i = p.y * w + p.x;
    if (bayerChannel(p, params[2]) == 1) { green[i] = mosaic[i].g; return; }
    // Reflect across the image edge to retain CFA parity.
    int x = int(p.x), y = int(p.y);
    int left = x == 0 ? 1 : x - 1, right = p.x + 1 == w ? x - 1 : x + 1;
    int up = y == 0 ? 1 : y - 1, down = p.y + 1 == h ? y - 1 : y + 1;
    int l = mosaic[y * w + left].g, r = mosaic[y * w + right].g;
    int u = mosaic[up * w + x].g, d = mosaic[down * w + x].g;
    uint gx = abs(l-r), gy = abs(u-d);
    green[i] = ushort(gx < gy ? (l+r+1)/2 : gy < gx ? (u+d+1)/2 : (l+r+u+d+2)/4);
}

kernel void phosdeckBayerRGB(device const ushort4 *mosaic [[buffer(0)]],
                             device const ushort *green [[buffer(1)]],
                             constant uint *params [[buffer(2)]],
                             device ushort4 *output [[buffer(3)]],
                             uint2 p [[thread_position_in_grid]]) {
    uint w = params[0], h = params[1], i = p.y * w + p.x;
    ushort4 rgb = mosaic[i];
    rgb.g = green[i];
    uint channel = bayerChannel(p, params[2]);
    for (uint c = 0; c <= 2; c += 2) {
        if (c == channel) continue;
        int delta = 0, count = 0;
        for (int y = max(0, int(p.y)-1); y <= min(int(h)-1, int(p.y)+1); ++y) {
            for (int x = max(0, int(p.x)-1); x <= min(int(w)-1, int(p.x)+1); ++x) {
                if (bayerChannel(uint2(x,y), params[2]) != c) continue;
                uint j = y*w+x;
                delta += int(mosaic[j][c]) - int(green[j]);
                ++count;
            }
        }
        rgb[c] = ushort(clamp(int(green[i]) + delta / max(count, 1), 0, 65535));
    }
    output[i] = rgb;
}
)metal";
@interface PhosdeckBayerDevice : NSObject
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLComputePipelineState> green;
@property(nonatomic, strong) id<MTLComputePipelineState> rgb;
@end
@implementation PhosdeckBayerDevice
@end

static PhosdeckBayerDevice *renderer() {
    static PhosdeckBayerDevice *state;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:bayerSource] options:nil error:nil];
        id<MTLFunction> green = [library newFunctionWithName:@"phosdeckBayerGreen"];
        id<MTLFunction> rgb = [library newFunctionWithName:@"phosdeckBayerRGB"];
        if (!green || !rgb) return;
        state = [PhosdeckBayerDevice new];
        state.queue = [device newCommandQueue];
        state.green = [device newComputePipelineStateWithFunction:green error:nil];
        state.rgb = [device newComputePipelineStateWithFunction:rgb error:nil];
    });
    return state;
}

extern "C" bool phosdeck_metal_bayer_available() {
    PhosdeckBayerDevice *state = renderer();
    return state.queue && state.green && state.rgb;
}

bool phosdeck_demosaic_bayer(uint16_t (*image)[4], uint32_t width, uint32_t height, uint32_t filters) {
    @autoreleasepool {
        if (!image || width < 2 || height < 2 || !phosdeck_metal_bayer_available()) return false;
        const size_t count = size_t(width) * height;
        if (count > 64 * 1024 * 1024) return false;
        PhosdeckBayerDevice *state = renderer();
        id<MTLDevice> device = state.queue.device;
        id<MTLBuffer> mosaic = [device newBufferWithBytes:image length:count * 8 options:MTLResourceStorageModeShared];
        id<MTLBuffer> green = [device newBufferWithLength:count * 2 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> output = [device newBufferWithLength:count * 8 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [state.queue commandBuffer];
        if (!mosaic || !green || !output || !command) return false;
        const uint32_t params[] = {width, height, filters};
        for (id<MTLComputePipelineState> pipeline in @[state.green, state.rgb]) {
            id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
            if (!encoder) return false;
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:mosaic offset:0 atIndex:0];
            [encoder setBuffer:green offset:0 atIndex:1];
            [encoder setBytes:params length:sizeof(params) atIndex:2];
            if (pipeline == state.rgb) [encoder setBuffer:output offset:0 atIndex:3];
            [encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [encoder endEncoding];
        }
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) return false;
        std::memcpy(image, output.contents, count * 8);
        return true;
    }
}
