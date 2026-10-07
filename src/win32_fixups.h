/*
 * Included first by module.c on Windows. In-tree VLC builds get poll()/struct pollfd
 * from vlc_fixups.h, which the SDK does not ship; vlc_threads.h needs them in an inline.
 */
#ifndef HDDVD_WIN32_FIXUPS_H
#define HDDVD_WIN32_FIXUPS_H

#ifndef _WIN32_WINNT
# define _WIN32_WINNT 0x0601 /* Windows 7, the VLC 3.0 minimum on x64 */
#endif
#include <winsock2.h>

#define poll(fds, nfds, timeout) WSAPoll(fds, nfds, timeout)

#endif
