#ifndef PHOSDECK_LIBRAW_BRIDGE_H
#define PHOSDECK_LIBRAW_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t openError;
    int32_t unpackError;
    int32_t dataErrorCount;
    uint32_t processWarnings;

    int32_t rawWidth;
    int32_t rawHeight;
    int32_t width;
    int32_t height;
    int32_t flip;
    int32_t colors;
    bool hasColorFilterArray;
    bool isXTrans;
    bool isDNG;
    bool isUnsupported;

    uint32_t blackLevel;
    uint32_t whiteLevel;
    uint32_t dataMaximum;
    int32_t rawBits;

    float camMul[4];
    float rgbCam[3][4];

    uint16_t fujiFilmMode;
    char make[64];
    char model[64];
    char normalizedModel[64];
    char decoderName[96];
    char nikonPictureControl[24];
    char errorMessage[256];
} PhosdeckLibRawProbe;

typedef struct {
    int32_t errorCode;
    int32_t dataErrorCount;
    int32_t width;
    int32_t height;
    int32_t colors;
    int32_t bits;
    uint16_t *pixels;
    size_t pixelCount;
    char errorMessage[256];
} PhosdeckLibRawImage;

void phosdeck_libraw_probe(const char *path, bool verifyBitstream, PhosdeckLibRawProbe *out);

bool phosdeck_metal_bayer_available(void);

void phosdeck_libraw_decode_linear16(
    const char *path,
    bool halfSize,
    bool metalBayer,
    bool useCustomWB,
    float rMul,
    float g1Mul,
    float bMul,
    float g2Mul,
    PhosdeckLibRawImage *out
);

void phosdeck_libraw_free_image(PhosdeckLibRawImage *image);

const char *phosdeck_libraw_version(void);

#ifdef __cplusplus
}
#endif

#endif
