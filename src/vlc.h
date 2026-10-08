/*
 * The VLC plugin API as seen from Zig: build.zig runs this header through
 * std.Build.Step.TranslateC and exposes the result as the "vlc" module.
 * Add VLC headers here as the plugin needs them.
 */
#ifdef _WIN32
# include "win32_fixups.h" /* must precede the VLC headers */
#endif
#include <vlc_common.h>
#include <vlc_messages.h>
#include <vlc_demux.h>
#include <vlc_es.h>
#include <vlc_es_out.h>
#include <vlc_block.h>
#include <vlc_stream.h>
#include <vlc_input.h>
#include <vlc_codec.h>
#include <vlc_subpicture.h>
#include <vlc_picture.h>
#include <vlc_aout.h>
