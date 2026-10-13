/*
 * Memory shared with VLC: allocated by one side and freed by the other (titles, seekpoints, ES format strings
 * and extra data, strings VLC returns). It must come from VLC's C runtime.
 *
 * On Windows, VLC 3 and its plugins use msvcrt.dll, while Zig links the plugin against the UCRT: two heaps,
 * and freeing a block on the wrong one corrupts it. There, every malloc/calloc/realloc/free/strdup in the C
 * glue and in VLC's static inline helpers (vlc_input_title_New, vlc_alloc…) goes to msvcrt.dll's (crt.c).
 * Elsewhere there is one C runtime and these are the usual functions.
 *
 * Zig code uses hddvd_vlc_malloc/hddvd_vlc_free for memory VLC frees or gives it; its own memory stays on
 * std.heap.c_allocator.
 */
#ifndef HDDVD_CRT_H
#define HDDVD_CRT_H

#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
# include <malloc.h>
#endif

void *hddvd_vlc_malloc(size_t size);
void *hddvd_vlc_calloc(size_t n, size_t size);
void *hddvd_vlc_realloc(void *p, size_t size);
void hddvd_vlc_free(void *p);
char *hddvd_vlc_strdup(const char *s);

#ifdef _WIN32
/* After the C runtime headers, so their declarations keep their own names. */
# define malloc(size) hddvd_vlc_malloc(size)
# define calloc(n, size) hddvd_vlc_calloc(n, size)
# define realloc(p, size) hddvd_vlc_realloc(p, size)
# define free(p) hddvd_vlc_free(p)
# define strdup(s) hddvd_vlc_strdup(s)
#endif

#endif
