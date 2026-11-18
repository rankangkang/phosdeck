#include "PhotoToolPixels.h"

#include <math.h>
#include <string.h>

bool PhosdeckValidatePluginRGBA32F(const void *bytes, size_t pixelCount) {
    const unsigned char *samples = bytes;
    for (size_t index = 0; index < pixelCount; index++) {
        float pixel[4];
        memcpy(pixel, samples + index * sizeof(pixel), sizeof(pixel));
        const float red = pixel[0], green = pixel[1], blue = pixel[2], alpha = pixel[3];
        if (!isfinite(red) || !isfinite(green) || !isfinite(blue) || !(alpha >= 0 && alpha <= 1)) {
            return false;
        }
        if (alpha == 0 && (red != 0 || green != 0 || blue != 0)) {
            return false;
        }
    }
    return true;
}
