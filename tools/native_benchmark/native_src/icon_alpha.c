/*
 * icon_alpha.c — Native alpha scan + mask application for icon pixel buffers
 *
 * Replaces two AHK NumGet/NumPut loops that cost 1.5ms-14.6ms per icon
 * with native C that does the same in ~3-10us (500-1700x speedup).
 *
 * Pixel format: BGRA (4 bytes per pixel), alpha at byte offset +3
 *
 * Build (MSVC x64):
 *   cl /O2 /c /GS- /Zl icon_alpha.c
 *
 * Build (MSVC x86):
 *   cl /O2 /c /GS- /Zl icon_alpha.c
 *
 * No CRT dependency. No imports. Pure computation on buffers.
 */

/* Exported calling convention */
#ifdef _WIN64
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __declspec(dllexport) __cdecl
#endif

typedef unsigned char  uint8_t;
typedef unsigned int   uint32_t;
typedef unsigned long long uint64_t;

/*
 * icon_scan_and_apply_mask
 *
 * Combined alpha scan + mask application in a single function.
 *
 * Parameters:
 *   pixels       - BGRA pixel buffer (modified in-place if mask applied)
 *   maskPixels   - BGRA mask buffer (NULL if no mask available)
 *   pixelCount   - Number of pixels (width * height)
 *
 * Returns:
 *   1 if original pixels had alpha channel (alpha > 0 found)
 *   0 if no alpha found (mask was applied if maskPixels != NULL)
 *
 * Behavior:
 *   1. Scan alpha bytes at stride 4 for any non-zero value
 *   2. If alpha found → return 1 (pixels unchanged)
 *   3. If no alpha AND maskPixels != NULL → apply mask:
 *      - mask pixel & 0xFFFFFF == 0 (black) → set alpha to 255 (opaque)
 *      - mask pixel & 0xFFFFFF != 0 (white) → set alpha to 0 (transparent)
 *   4. Return 0
 */
int EXPORT icon_scan_and_apply_mask(
    uint8_t *pixels,
    const uint8_t *maskPixels,
    uint32_t pixelCount
) {
    uint32_t i;
    uint8_t *alpha_ptr;
    const uint32_t *mask_ptr;
    uint32_t *pixel_ptr;

    if (!pixels || pixelCount == 0)
        return 0;

    /* --- Phase 1: Alpha scan --- */
    /* Check alpha byte (offset +3) of each BGRA pixel */
    /* Process 4 pixels at a time when possible for better throughput */

    alpha_ptr = pixels + 3;  /* Point to first alpha byte */

    /* Unrolled loop: check 8 pixels at a time */
    i = 0;
    while (i + 8 <= pixelCount) {
        if (alpha_ptr[0]  | alpha_ptr[4]  | alpha_ptr[8]  | alpha_ptr[12] |
            alpha_ptr[16] | alpha_ptr[20] | alpha_ptr[24] | alpha_ptr[28])
            return 1;  /* Found non-zero alpha */
        alpha_ptr += 32;  /* 8 pixels * 4 bytes */
        i += 8;
    }

    /* Handle remaining pixels */
    while (i < pixelCount) {
        if (*alpha_ptr)
            return 1;
        alpha_ptr += 4;
        i++;
    }

    /* --- Phase 2: No alpha found, apply mask if available --- */
    if (!maskPixels)
        return 0;

    mask_ptr = (const uint32_t *)maskPixels;
    pixel_ptr = (uint32_t *)pixels;

    /* Process pixels: read mask, set alpha byte */
    for (i = 0; i < pixelCount; i++) {
        if ((mask_ptr[i] & 0x00FFFFFF) == 0) {
            /* Mask is black → opaque: set alpha to 0xFF */
            pixel_ptr[i] |= 0xFF000000;
        } else {
            /* Mask is white → transparent: clear alpha */
            pixel_ptr[i] &= 0x00FFFFFF;
        }
    }

    return 0;
}

/*
 * icon_scan_alpha_only
 *
 * Lightweight scan-only variant (no mask application).
 * Useful when you just need to know if alpha exists.
 *
 * Returns: 1 if any alpha > 0 found, 0 otherwise
 */
int EXPORT icon_scan_alpha_only(
    const uint8_t *pixels,
    uint32_t pixelCount
) {
    uint32_t i;
    const uint8_t *alpha_ptr;

    if (!pixels || pixelCount == 0)
        return 0;

    alpha_ptr = pixels + 3;

    /* Unrolled: 8 pixels at a time */
    i = 0;
    while (i + 8 <= pixelCount) {
        if (alpha_ptr[0]  | alpha_ptr[4]  | alpha_ptr[8]  | alpha_ptr[12] |
            alpha_ptr[16] | alpha_ptr[20] | alpha_ptr[24] | alpha_ptr[28])
            return 1;
        alpha_ptr += 32;
        i += 8;
    }

    while (i < pixelCount) {
        if (*alpha_ptr)
            return 1;
        alpha_ptr += 4;
        i++;
    }

    return 0;
}
