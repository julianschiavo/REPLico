#ifndef REPLICO_RUNTIME_ARTIFACT_H
#define REPLICO_RUNTIME_ARTIFACT_H

#include "NodeIdentity.h"
#include <errno.h>
#include <unistd.h>
#include <zlib.h>

extern const unsigned char replico_node_gzip[];
extern const unsigned char replico_node_license[];

static inline int replico_write_bytes(int fd, const unsigned char *bytes, size_t count) {
    while (count > 0) {
        ssize_t written = write(fd, bytes, count);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return written < 0 ? errno : EIO;
        }
        bytes += written;
        count -= (size_t)written;
    }
    return 0;
}

/** Write the complete Node executable to an open descriptor, returning zero or errno. */
static inline int replico_write_node_executable(int fd) {
    z_stream stream = {0};
    stream.next_in = (Bytef *)replico_node_gzip;
    stream.avail_in = REPLICO_NODE_GZIP_SIZE;
    int status = inflateInit2(&stream, MAX_WBITS + 16);
    if (status != Z_OK) {
        return status == Z_MEM_ERROR ? ENOMEM : EINVAL;
    }
    unsigned char buffer[64 * 1024];
    int error = 0;
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            error = status == Z_MEM_ERROR ? ENOMEM : EIO;
            break;
        }
        error = replico_write_bytes(fd, buffer, sizeof(buffer) - stream.avail_out);
    } while (!error && status != Z_STREAM_END);
    if (!error && (stream.total_out != REPLICO_NODE_SIZE || stream.avail_in != 0)) {
        error = EIO;
    }
    inflateEnd(&stream);
    return error;
}

/** Write Node's original license and third-party notices, returning zero or errno. */
static inline int replico_write_node_license(int fd) {
    return replico_write_bytes(fd, replico_node_license, REPLICO_NODE_LICENSE_SIZE);
}

#endif
