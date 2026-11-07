// iOS shim: libslic3r only uses OpenSSL for MD5 (3MF and file checksums), so
// map that API onto CommonCrypto instead of cross-compiling OpenSSL.
#pragma once
#include <CommonCrypto/CommonDigest.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
typedef CC_MD5_CTX MD5_CTX;
#define MD5_DIGEST_LENGTH CC_MD5_DIGEST_LENGTH
static inline int MD5_Init(MD5_CTX *c) { return CC_MD5_Init(c); }
static inline int MD5_Update(MD5_CTX *c, const void *data, size_t len) { return CC_MD5_Update(c, data, (CC_LONG)len); }
static inline int MD5_Final(unsigned char *md, MD5_CTX *c) { return CC_MD5_Final(md, c); }
static inline unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md) { return CC_MD5(d, (CC_LONG)n, md); }
#pragma clang diagnostic pop
