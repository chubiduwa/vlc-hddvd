/*
 * VLC's C runtime for memory shared with VLC (see crt.h): msvcrt.dll's allocator on Windows, the usual one
 * elsewhere. And, on Linux, the C++ static destructors run when VLC unloads the plugin.
 */
#include "crt.h"

#if defined(__linux__)
/*
 * The C++ code linked in (libc++, RtAudio) registers its static destructors with __cxa_atexit for this
 * library (&__dso_handle). A shared library normally runs them at dlclose through __cxa_finalize, called from
 * crtbeginS.o, which Zig does not link: they stayed registered, and exit() called them after VLC had unloaded
 * the plugin (a crash at VLC's exit).
 */
extern void *__dso_handle;
extern void __cxa_finalize(void *dso);

__attribute__((destructor)) static void RunStaticDestructors(void)
{
    __cxa_finalize(&__dso_handle);
}
#endif

#ifdef _WIN32
# include <windows.h>

/* crt.h's macros are not wanted here. */
# undef malloc
# undef calloc
# undef realloc
# undef free
# undef strdup

static struct {
    void *(__cdecl *malloc)(size_t);
    void *(__cdecl *calloc)(size_t, size_t);
    void *(__cdecl *realloc)(void *, size_t);
    void (__cdecl *free)(void *);
    char *(__cdecl *strdup)(const char *);
} crt;
static INIT_ONCE crt_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK Resolve(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
    (void)once;
    (void)param;
    (void)ctx;
    /* VLC has loaded it already; LoadLibrary only takes a reference if not (it is never released). */
    HMODULE m = GetModuleHandleW(L"msvcrt.dll");
    if (m == NULL)
        m = LoadLibraryW(L"msvcrt.dll");
    if (m != NULL) {
        crt.malloc = (void *(__cdecl *)(size_t))(void (*)(void))GetProcAddress(m, "malloc");
        crt.calloc = (void *(__cdecl *)(size_t, size_t))(void (*)(void))GetProcAddress(m, "calloc");
        crt.realloc = (void *(__cdecl *)(void *, size_t))(void (*)(void))GetProcAddress(m, "realloc");
        crt.free = (void (__cdecl *)(void *))(void (*)(void))GetProcAddress(m, "free");
        crt.strdup = (char *(__cdecl *)(const char *))(void (*)(void))GetProcAddress(m, "_strdup");
    }
    if (crt.malloc == NULL || crt.calloc == NULL || crt.realloc == NULL || crt.free == NULL || crt.strdup == NULL) {
        /* No msvcrt.dll (cannot happen with VLC 3): our own runtime, as before. */
        crt.malloc = malloc;
        crt.calloc = calloc;
        crt.realloc = realloc;
        crt.free = free;
        crt.strdup = _strdup;
    }
    return TRUE;
}

static void Init(void)
{
    InitOnceExecuteOnce(&crt_once, Resolve, NULL, NULL);
}

void *hddvd_vlc_malloc(size_t size)
{
    Init();
    return crt.malloc(size);
}

void *hddvd_vlc_calloc(size_t n, size_t size)
{
    Init();
    return crt.calloc(n, size);
}

void *hddvd_vlc_realloc(void *p, size_t size)
{
    Init();
    return crt.realloc(p, size);
}

void hddvd_vlc_free(void *p)
{
    Init();
    crt.free(p);
}

char *hddvd_vlc_strdup(const char *s)
{
    Init();
    return crt.strdup(s);
}

#else

void *hddvd_vlc_malloc(size_t size)
{
    return malloc(size);
}

void *hddvd_vlc_calloc(size_t n, size_t size)
{
    return calloc(n, size);
}

void *hddvd_vlc_realloc(void *p, size_t size)
{
    return realloc(p, size);
}

void hddvd_vlc_free(void *p)
{
    free(p);
}

char *hddvd_vlc_strdup(const char *s)
{
    return strdup(s);
}

#endif
