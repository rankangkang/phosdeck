#include "LibRawBridge.h"
#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

bool phosdeck_demosaic_bayer(uint16_t (*image)[4], uint32_t width, uint32_t height, uint32_t filters);

namespace {

class BayerProcessor final : public LibRaw {
public:
    bool interpolated = false;
    void enableMetal() {
        callbacks.interpolate_bayer_cb = [](void *context) {
            auto &processor = *static_cast<BayerProcessor *>(static_cast<LibRaw *>(context));
            auto &data = processor.imgdata;
            // At this stage LibRaw has merged G2 into G1. Accept only a
            // repeating RGB Bayer tile with the two greens opposite each other.
            int counts[4] = {};
            for (int row = 0; row < 8; ++row) {
                for (int col = 0; col < 2; ++col) {
                    int channel = processor.FC(row, col);
                    if (channel != processor.FC(row % 2, col)) return;
                    if (row < 2) ++counts[channel];
                }
            }
            if (counts[0] != 1 || counts[1] != 2 || counts[2] != 1 ||
                processor.FC(0, 0) == processor.FC(0, 1) ||
                processor.FC(0, 0) == processor.FC(1, 0) ||
                processor.FC(1, 1) == processor.FC(0, 1) ||
                processor.FC(1, 1) == processor.FC(1, 0)) return;
            processor.interpolated = phosdeck_demosaic_bayer(data.image, data.sizes.width, data.sizes.height, data.idata.filters);
        };
    }
};


void copyString(char *dst, size_t capacity, const char *src) {
    if (!dst || capacity == 0) { return; }
    if (!src) { dst[0] = '\0'; return; }
    size_t len = strnlen(src, capacity - 1);
    std::memcpy(dst, src, len);
    dst[len] = '\0';
}

struct DataErrorCounter {
    int32_t count = 0;
};

void countDataError(void *context, const char *, const INT64) {
    if (!context) { return; }
    static_cast<DataErrorCounter *>(context)->count += 1;
}

uint32_t effectiveBlackLevel(const libraw_colordata_t &color) {
    if (color.black > 0) { return color.black; }
    uint32_t best = 0;
    for (int i = 0; i < 4; ++i) {
        if (color.cblack[i] > 0) {
            best = best == 0 ? color.cblack[i] : std::min(best, color.cblack[i]);
        }
    }
    return best;
}

int32_t inferSensorBits(const libraw_data_t &img) {
    unsigned bps = img.rawdata.color.raw_bps;
    if (bps >= 8 && bps <= 16) { return static_cast<int32_t>(bps); }
    unsigned maxVal = img.color.maximum;
    if (maxVal >= 200 && maxVal <= 255) { return 8; }
    if (maxVal >= 900 && maxVal <= 1023) { return 10; }
    if (maxVal >= 3000 && maxVal <= 4095) { return 12; }
    if (maxVal >= 12000 && maxVal <= 16383) { return 14; }
    if (maxVal >= 48000 && maxVal <= 65535) { return 16; }
    return 0;
}

} // namespace

extern "C" {

const char *phosdeck_libraw_version(void) {
    return LibRaw::version();
}

void phosdeck_libraw_probe(const char *path, bool verifyBitstream, PhosdeckLibRawProbe *out) {
    if (!out) { return; }
    std::memset(out, 0, sizeof(*out));
    if (!path || path[0] == '\0') {
        out->openError = LIBRAW_INPUT_CLOSED;
        copyString(out->errorMessage, sizeof(out->errorMessage), "Empty RAW path");
        return;
    }

    try {
        std::unique_ptr<LibRaw> processor(new LibRaw());
        DataErrorCounter counter;
        processor->set_dataerror_handler(&countDataError, &counter);
        processor->imgdata.rawparams.max_raw_memory_mb = 512;

        int rc = processor->open_file(path);
        out->openError = rc;
        if (rc != LIBRAW_SUCCESS) {
            out->isUnsupported = (rc == LIBRAW_FILE_UNSUPPORTED);
            copyString(out->errorMessage, sizeof(out->errorMessage), LibRaw::strerror(rc));
            return;
        }

        const libraw_data_t &img = processor->imgdata;
        out->rawWidth = img.sizes.raw_width;
        out->rawHeight = img.sizes.raw_height;
        out->width = img.sizes.iwidth;
        out->height = img.sizes.iheight;
        out->flip = img.sizes.flip;
        out->colors = img.idata.colors;
        out->hasColorFilterArray = img.idata.filters != 0;
        out->isXTrans = (img.idata.filters == 9);
        out->isDNG = (img.idata.dng_version != 0);
        out->blackLevel = effectiveBlackLevel(img.color);
        out->whiteLevel = img.color.maximum;
        out->fujiFilmMode = img.makernotes.fuji.FilmMode;

        for (int i = 0; i < 4; ++i) { out->camMul[i] = img.color.cam_mul[i]; }
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 4; ++c) { out->rgbCam[r][c] = img.color.rgb_cam[r][c]; }
        }

        copyString(out->make, sizeof(out->make), img.idata.make);
        copyString(out->model, sizeof(out->model), img.idata.model);
        copyString(out->normalizedModel, sizeof(out->normalizedModel), img.idata.normalized_model);
        copyString(out->nikonPictureControl, sizeof(out->nikonPictureControl), img.makernotes.nikon.PictureControlName);

        libraw_decoder_info_t info;
        std::memset(&info, 0, sizeof(info));
        if (processor->get_decoder_info(&info) == LIBRAW_SUCCESS && info.decoder_name) {
            copyString(out->decoderName, sizeof(out->decoderName), info.decoder_name);
            if ((info.decoder_flags & LIBRAW_DECODER_UNSUPPORTED_FORMAT) != 0) {
                out->isUnsupported = true;
            }
        }

        if (verifyBitstream) {
            int unpackRC = processor->unpack();
            out->unpackError = unpackRC;
            out->dataErrorCount = counter.count;
            out->processWarnings = img.process_warnings;
            out->dataMaximum = img.color.data_maximum;
            out->blackLevel = effectiveBlackLevel(img.color);
            out->whiteLevel = img.color.maximum;
            out->rawBits = inferSensorBits(img);
            if (unpackRC != LIBRAW_SUCCESS) {
                out->isUnsupported = (unpackRC == LIBRAW_FILE_UNSUPPORTED);
                copyString(out->errorMessage, sizeof(out->errorMessage), LibRaw::strerror(unpackRC));
            } else if (counter.count > 0) {
                copyString(out->errorMessage, sizeof(out->errorMessage), "LibRaw reported corrupted RAW bitstream data");
            }
        } else {
            out->rawBits = inferSensorBits(img);
        }
        processor->recycle();
    } catch (...) {
        out->openError = LIBRAW_UNSPECIFIED_ERROR;
        copyString(out->errorMessage, sizeof(out->errorMessage), "Unexpected LibRaw internal exception");
    }
}

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
) {
    if (!out) { return; }
    std::memset(out, 0, sizeof(*out));
    if (!path || path[0] == '\0') {
        out->errorCode = LIBRAW_INPUT_CLOSED;
        copyString(out->errorMessage, sizeof(out->errorMessage), "Empty RAW path");
        return;
    }

    try {
        auto processor = std::make_unique<BayerProcessor>();
        if (metalBayer && !halfSize) processor->enableMetal();
        DataErrorCounter counter;
        processor->set_dataerror_handler(&countDataError, &counter);

        libraw_output_params_t &p = processor->imgdata.params;
        processor->imgdata.rawparams.max_raw_memory_mb = 512;
        p.output_bps = 16;
        p.output_color = 1; // Linear sRGB primaries
        p.gamm[0] = 1.0;
        p.gamm[1] = 1.0;
        p.no_auto_bright = 1;
        p.highlight = 0;
        p.half_size = halfSize ? 1 : 0;
        p.user_qual = halfSize ? 0 : 3; // AHD / X-Trans 3-pass
        if (useCustomWB && std::isfinite(rMul) && std::isfinite(g1Mul) && std::isfinite(bMul) && std::isfinite(g2Mul) &&
            rMul > 0 && g1Mul > 0 && bMul > 0 && g2Mul > 0) {
            p.use_camera_wb = 0;
            p.use_auto_wb = 0;
            p.user_mul[0] = rMul;
            p.user_mul[1] = g1Mul;
            p.user_mul[2] = bMul;
            p.user_mul[3] = g2Mul;
        } else {
            p.use_camera_wb = 1;
            p.use_auto_wb = 0;
        }

        int rc = processor->open_file(path);
        if (rc != LIBRAW_SUCCESS) {
            out->errorCode = rc;
            copyString(out->errorMessage, sizeof(out->errorMessage), LibRaw::strerror(rc));
            return;
        }
        rc = processor->unpack();
        out->dataErrorCount = counter.count;
        if (rc != LIBRAW_SUCCESS) {
            out->errorCode = rc;
            copyString(out->errorMessage, sizeof(out->errorMessage), LibRaw::strerror(rc));
            processor->recycle();
            return;
        }
        if (counter.count > 0) {
            out->errorCode = LIBRAW_DATA_ERROR;
            copyString(out->errorMessage, sizeof(out->errorMessage), "LibRaw reported corrupted RAW bitstream data");
            processor->recycle();
            return;
        }
        rc = processor->dcraw_process();
        if (rc != LIBRAW_SUCCESS) {
            out->errorCode = rc;
            copyString(out->errorMessage, sizeof(out->errorMessage), LibRaw::strerror(rc));
            processor->recycle();
            return;
        }

        if (metalBayer && !halfSize && !processor->interpolated) {
            out->errorCode = LIBRAW_UNSPECIFIED_ERROR;
            copyString(out->errorMessage, sizeof(out->errorMessage), "Metal Bayer demosaic unavailable for this source");
            return;
        }

        int memErr = 0;
        libraw_processed_image_t *img = processor->dcraw_make_mem_image(&memErr);
        if (!img || memErr != LIBRAW_SUCCESS || img->type != LIBRAW_IMAGE_BITMAP || img->bits != 16 || img->colors != 3) {
            if (img) { LibRaw::dcraw_clear_mem(img); }
            out->errorCode = memErr != 0 ? memErr : LIBRAW_UNSPECIFIED_ERROR;
            copyString(out->errorMessage, sizeof(out->errorMessage), "LibRaw did not produce a 16-bit RGB bitmap");
            processor->recycle();
            return;
        }

        size_t samples = static_cast<size_t>(img->width) * static_cast<size_t>(img->height) * 3;
        size_t expectedBytes = samples * sizeof(uint16_t);
        if (img->width == 0 || img->height == 0 || img->data_size < expectedBytes) {
            LibRaw::dcraw_clear_mem(img);
            out->errorCode = LIBRAW_DATA_ERROR;
            copyString(out->errorMessage, sizeof(out->errorMessage), "LibRaw bitmap size mismatch");
            processor->recycle();
            return;
        }

        uint16_t *buffer = static_cast<uint16_t *>(std::malloc(expectedBytes));
        if (!buffer) {
            LibRaw::dcraw_clear_mem(img);
            out->errorCode = LIBRAW_UNSUFFICIENT_MEMORY;
            copyString(out->errorMessage, sizeof(out->errorMessage), "Out of memory allocating LibRaw output");
            processor->recycle();
            return;
        }
        std::memcpy(buffer, img->data, expectedBytes);
        out->width = img->width;
        out->height = img->height;
        out->colors = img->colors;
        out->bits = img->bits;
        out->pixels = buffer;
        out->pixelCount = samples;
        out->errorCode = LIBRAW_SUCCESS;

        LibRaw::dcraw_clear_mem(img);
        processor->recycle();
    } catch (...) {
        out->errorCode = LIBRAW_UNSPECIFIED_ERROR;
        copyString(out->errorMessage, sizeof(out->errorMessage), "Unexpected LibRaw decode exception");
    }
}

void phosdeck_libraw_free_image(PhosdeckLibRawImage *image) {
    if (!image) { return; }
    if (image->pixels) {
        std::free(image->pixels);
        image->pixels = nullptr;
    }
    image->pixelCount = 0;
}

} // extern "C"
