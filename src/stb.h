/*
 * stb_image (PNG, JPEG) and stb_truetype for the Advanced Content engine (adv/image.zig, adv/font.zig), from the
 * stb dependency in build.zig.zon. Seen by Zig through translate-c; the implementation is in stb.c.
 */
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include <stb_image.h>
#include <stb_truetype.h>
