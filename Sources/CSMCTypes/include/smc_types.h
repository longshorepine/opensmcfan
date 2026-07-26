#ifndef SMC_TYPES_H
#define SMC_TYPES_H

#include <stdint.h>

// ── SMC struct definitions matching the AppleSMC kernel driver ABI ──

typedef struct {
    uint8_t    major;
    uint8_t    minor;
    uint8_t    build;
    uint8_t    reserved;
    uint16_t   release;
} SMCVersion_t;

typedef struct {
    uint16_t   version;
    uint16_t   length;
    uint32_t   cpuPLimit;
    uint32_t   gpuPLimit;
    uint32_t   memPLimit;
} SMCPLimitData_t;

typedef struct {
    uint32_t   dataSize;
    uint32_t   dataType;
    uint8_t    dataAttributes;
} SMCKeyInfoData_t;

typedef struct {
    uint32_t         key;
    SMCVersion_t     vers;
    SMCPLimitData_t  pLimitData;
    SMCKeyInfoData_t keyInfo;
    uint8_t          result;
    uint8_t          status;
    uint8_t          data8;
    uint32_t         data32;
    uint8_t          bytes[32];
} SMCKeyData_t;

// SMC command selectors (written to data8 before calling)
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_KEYINFO 9

// IOConnectCallStructMethod selector for AppleSMC
#define KERNEL_INDEX_SMC     2

#endif /* SMC_TYPES_H */
