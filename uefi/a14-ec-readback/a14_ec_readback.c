#ifdef MDE_CPU_AARCH64
#include <Uefi.h>
#include <Protocol/LoadedImage.h>
#include <Protocol/SimpleFileSystem.h>
#else
#include "uefi_min.h"
#endif

#define FLASH_SIZE       0x100000U
#define READ_CHUNK       64U
#define I2C_INSTANCE     6U
#define I2C_SLAVE        0x5bU
#define I2C_FREQUENCY_KHZ 400U
#define I2C_TIMEOUT_US   2500U
#define EC_BRIDGE_MODE_REGISTER 0x1059U

/* The only SPI instructions present in this program. */
#define SPI_FAST_READ    0x0bU
#define SPI_READ_ID      0x9fU

#define I2C_DESCRIPTOR_WRITE_FLAGS 7U
#define I2C_DESCRIPTOR_READ_FLAGS  11U

typedef int I2C_STATUS;
typedef struct {
    UINT32 bus_frequency_khz;
    UINT32 slave_address;
    UINT32 mode;
    UINT32 max_clock_stretch_us;
    UINT32 core_configuration1;
    UINT32 core_configuration2;
} I2C_SLAVE_CONFIG;

typedef struct {
    UINT8 *buffer;
    UINT32 length;
    UINT32 flags;
} I2C_DESCRIPTOR;

typedef I2C_STATUS (EFIAPI *I2C_OPEN)(UINT32, VOID **);
typedef I2C_STATUS (EFIAPI *I2C_TRANSFER)(VOID *, I2C_SLAVE_CONFIG *,
                                          I2C_DESCRIPTOR *, UINT16,
                                          VOID *, VOID *, UINT32, UINT32 *);
typedef I2C_STATUS (EFIAPI *I2C_CLOSE)(VOID *);
typedef struct {
    UINT64 revision;
    I2C_OPEN open;
    VOID *power_on;
    VOID *power_off;
    I2C_TRANSFER transfer;
    I2C_CLOSE close;
} QCOM_I2C_PROTOCOL;

static EFI_SYSTEM_TABLE *st;
static EFI_BOOT_SERVICES *bs;
static QCOM_I2C_PROTOCOL *i2c;
static VOID *i2c_handle;

static EFI_GUID qcom_i2c_guid = {
    0xb27ae8b1, 0x3e10, 0x4d07,
    {0xab, 0x5c, 0xeb, 0x9a, 0x6d, 0xc6, 0xfa, 0x8f}
};
static EFI_GUID loaded_image_guid = {
    0x5b1b31a1, 0x9562, 0x11d2,
    {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}
};
static EFI_GUID simple_fs_guid = {
    0x964e5b22U, 0x6459, 0x11d2,
    {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}
};

static CHAR16 msg_banner[] = {'A','1','4',' ','E','C',' ','r','e','a','d','b','a','c','k',' ','v','1','\r','\n',0};
static CHAR16 msg_readonly[] = {'S','P','I',' ','r','e','a','d','-','o','n','l','y',':',' ','0','x','9','f',' ','+',' ','0','x','0','b',' ','o','n','l','y','.','\r','\n',0};
static CHAR16 msg_start[] = {'R','e','a','d','i','n','g',' ','t','h','r','e','e',' ','1',' ','M','i','B',' ','p','a','s','s','e','s','.','.','.','\r','\n',0};
static CHAR16 msg_ok[] = {'O','K',':',' ','t','h','r','e','e',' ','p','a','s','s','e','s',' ','a','r','e',' ','i','d','e','n','t','i','c','a','l','.','\r','\n',0};
static CHAR16 msg_fail[] = {'F','A','I','L','-','C','L','O','S','E','D','.',' ','N','o',' ','E','C',' ','f','l','a','s','h',' ','w','r','i','t','e',' ','w','a','s',' ','i','s','s','u','e','d','.','\r','\n',0};
static CHAR16 err_protocol[] = {'E','R','R',':',' ','Q','u','a','l','c','o','m','m',' ','I','2','C',' ','p','r','o','t','o','c','o','l','.','\r','\n',0};
static CHAR16 err_i2c_open[] = {'E','R','R',':',' ','I','2','C',' ','i','n','s','t','a','n','c','e',' ','6',' ','o','p','e','n','.','\r','\n',0};
static CHAR16 err_bridge[] = {'E','R','R',':',' ','E','C',' ','0','x','1','0','5','9',' ','i','s',' ','n','o','t',' ','z','e','r','o',':',' ',0};
static CHAR16 err_jedec[] = {'E','R','R',':',' ','u','n','e','x','p','e','c','t','e','d',' ','J','E','D','E','C',':',' ',0};
static CHAR16 err_memory[] = {'E','R','R',':',' ','U','E','F','I',' ','m','e','m','o','r','y',' ','a','l','l','o','c','a','t','i','o','n','.','\r','\n',0};
static CHAR16 err_read[] = {'E','R','R',':',' ','S','P','I',' ','r','e','a','d',' ','t','r','a','n','s','a','c','t','i','o','n','.','\r','\n',0};
static CHAR16 err_mismatch[] = {'E','R','R',':',' ','t','h','r','e','e',' ','r','e','a','d',' ','p','a','s','s','e','s',' ','d','i','f','f','e','r','.','\r','\n',0};
static CHAR16 err_volume[] = {'E','R','R',':',' ','b','o','o','t',' ','F','A','T',' ','v','o','l','u','m','e','.','\r','\n',0};
static CHAR16 err_save[] = {'E','R','R',':',' ','w','r','i','t','i','n','g',' ','b','a','c','k','u','p',' ','f','i','l','e','s','.','\r','\n',0};

static void print(CHAR16 *s) { st->ConOut->OutputString(st->ConOut, s); }
static void print_hex_byte(UINT8 value, int newline)
{
    static const CHAR16 digits[] = {'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'};
    CHAR16 out[] = {'0','x','0','0',' ',0,0,0};
    out[2] = digits[value >> 4]; out[3] = digits[value & 15];
    if (newline) { out[4] = '\r'; out[5] = '\n'; out[6] = 0; }
    print(out);
}

static int bytes_equal(const UINT8 *a, const UINT8 *b, UINTN n)
{
    while (n--) if (*a++ != *b++) return 0;
    return 1;
}

static UINT32 crc32(const UINT8 *p, UINTN n)
{
    UINT32 crc = 0xffffffffU;
    while (n--) {
        UINT32 x = (crc ^ *p++) & 0xffU;
        UINT32 k;
        for (k = 0; k < 8; k++) x = (x >> 1) ^ (0xedb88320U & (0U - (x & 1U)));
        crc = (crc >> 8) ^ x;
    }
    return crc ^ 0xffffffffU;
}

static void append_char(UINT8 *b, UINTN *p, UINT8 c) { b[(*p)++] = c; }
static void append_text(UINT8 *b, UINTN *p, const char *s) { while (*s) b[(*p)++] = (UINT8)*s++; }
static void append_hex8(UINT8 *b, UINTN *p, UINT8 v)
{
    static const char h[] = "0123456789abcdef";
    append_char(b, p, (UINT8)h[v >> 4]); append_char(b, p, (UINT8)h[v & 15]);
}
static void append_hex32(UINT8 *b, UINTN *p, UINT32 v)
{
    int shift;
    for (shift = 28; shift >= 0; shift -= 4) append_char(b, p, (UINT8)"0123456789abcdef"[(v >> shift) & 15]);
}

static I2C_SLAVE_CONFIG config = { I2C_FREQUENCY_KHZ, I2C_SLAVE, 0, 500, 0, 0 };

static int transfer(UINT8 *buffer, UINT32 length, UINT32 flags)
{
    I2C_DESCRIPTOR descriptor;
    UINT32 transferred = 0;
    I2C_STATUS status;
    descriptor.buffer = buffer;
    descriptor.length = length;
    descriptor.flags = flags;
    status = i2c->transfer(i2c_handle, &config, &descriptor, 1, 0, 0,
                           I2C_TIMEOUT_US, &transferred);
    return status == 0 && transferred == length;
}

static int i2c_write(UINT8 *buffer, UINT32 length)
{ return transfer(buffer, length, I2C_DESCRIPTOR_WRITE_FLAGS); }
static int i2c_read(UINT8 *buffer, UINT32 length)
{ return transfer(buffer, length, I2C_DESCRIPTOR_READ_FLAGS); }

static int ec_register_read(UINT16 address, UINT8 *value)
{
    UINT8 select[3] = { 0x10, (UINT8)(address >> 8), (UINT8)address };
    UINT8 data_port = 0x11;
    return i2c_write(select, 3) && i2c_write(&data_port, 1) && i2c_read(value, 1);
}

static int spi_read_id(UINT8 id[3])
{
    UINT8 command_port = 0x17;
    UINT8 command[2] = { 0x18, SPI_READ_ID };
    return i2c_write(&command_port, 1) && i2c_write(command, 2) && i2c_read(id, 3);
}

static int spi_fast_read(UINT32 address, UINT8 *output)
{
    UINT8 command_port = 0x17;
    UINT8 command[6] = {
        0x18, SPI_FAST_READ, (UINT8)(address >> 16),
        (UINT8)(address >> 8), (UINT8)address, 0x00
    };
    return i2c_write(&command_port, 1) && i2c_write(command, 6) && i2c_read(output, READ_CHUNK);
}

static int read_pass(UINT8 *output)
{
    UINT32 address;
    for (address = 0; address < FLASH_SIZE; address += READ_CHUNK)
        if (!spi_fast_read(address, output + address)) return 0;
    return 1;
}

static EFI_STATUS save_file(EFI_FILE_PROTOCOL *root, CHAR16 *name, UINT8 *data, UINTN size)
{
    EFI_FILE_PROTOCOL *file = 0;
    EFI_STATUS status = root->Open(root, &file, name,
        EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
    if (EFI_ERROR(status)) return status;
    status = file->Write(file, &size, data);
    file->Close(file);
    return status;
}

static EFI_STATUS open_boot_volume(EFI_HANDLE image, EFI_FILE_PROTOCOL **root)
{
    EFI_LOADED_IMAGE_PROTOCOL *loaded = 0;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs = 0;
    EFI_STATUS status = bs->HandleProtocol(image, &loaded_image_guid, (VOID **)&loaded);
    if (EFI_ERROR(status)) return status;
    status = bs->HandleProtocol(loaded->DeviceHandle, &simple_fs_guid, (VOID **)&fs);
    if (EFI_ERROR(status)) return status;
    return fs->OpenVolume(fs, root);
}

static int accepted_id(UINT8 id[3])
{
    return (id[0] == 0xef || id[0] == 0xc8) && id[1] == 0x60 && id[2] == 0x14;
}

#ifdef MDE_CPU_AARCH64
#define A14_EFI_ENTRY UefiMain
#else
#define A14_EFI_ENTRY efi_main
#endif

EFI_STATUS EFIAPI A14_EFI_ENTRY(EFI_HANDLE image, EFI_SYSTEM_TABLE *system_table)
{
    EFI_FILE_PROTOCOL *root = 0;
    UINT8 *pass1 = 0, *pass2 = 0, *pass3 = 0, *report = 0;
    UINT8 bridge_mode = 0xff, id[3] = {0,0,0};
    UINT32 c1, c2, c3;
    UINTN rp = 0;
    EFI_STATUS status = EFI_ABORTED;
    CHAR16 n1[] = {'A','1','4','E','C','0','0','1','.','B','I','N',0};
    CHAR16 n2[] = {'A','1','4','E','C','0','0','2','.','B','I','N',0};
    CHAR16 n3[] = {'A','1','4','E','C','0','0','3','.','B','I','N',0};
    CHAR16 nr[] = {'A','1','4','E','C','.','T','X','T',0};

    st = system_table; bs = st->BootServices;
    print(msg_banner); print(msg_readonly);
    status = bs->LocateProtocol(&qcom_i2c_guid, 0, (VOID **)&i2c);
    if (EFI_ERROR(status) || !i2c || !i2c->open || !i2c->transfer || !i2c->close) {
        print(err_protocol); goto out;
    }
    if (i2c->open(I2C_INSTANCE, &i2c_handle) != 0 || !i2c_handle) {
        print(err_i2c_open); goto out;
    }
    status = EFI_ABORTED;

    /* Fail closed unless the bridge is already in the stock updater's read
     * mode. This application never changes EC register 0x1059. */
    if (!ec_register_read(EC_BRIDGE_MODE_REGISTER, &bridge_mode) || bridge_mode != 0) {
        print(err_bridge); print_hex_byte(bridge_mode, 1); goto close_i2c;
    }
    if (!spi_read_id(id) || !accepted_id(id)) {
        print(err_jedec); print_hex_byte(id[0], 0); print_hex_byte(id[1], 0);
        print_hex_byte(id[2], 1); goto close_i2c;
    }
    if (EFI_ERROR(bs->AllocatePool(EfiLoaderData, FLASH_SIZE, (VOID **)&pass1)) ||
        EFI_ERROR(bs->AllocatePool(EfiLoaderData, FLASH_SIZE, (VOID **)&pass2)) ||
        EFI_ERROR(bs->AllocatePool(EfiLoaderData, FLASH_SIZE, (VOID **)&pass3)) ||
        EFI_ERROR(bs->AllocatePool(EfiLoaderData, 1024, (VOID **)&report))) {
        print(err_memory); goto close_i2c;
    }

    print(msg_start);
    if (!read_pass(pass1) || !read_pass(pass2) || !read_pass(pass3)) {
        print(err_read); goto close_i2c;
    }
    if (!bytes_equal(pass1, pass2, FLASH_SIZE) || !bytes_equal(pass1, pass3, FLASH_SIZE)) {
        print(err_mismatch); goto close_i2c;
    }
    c1 = crc32(pass1, FLASH_SIZE); c2 = crc32(pass2, FLASH_SIZE); c3 = crc32(pass3, FLASH_SIZE);
    if (c1 != c2 || c1 != c3) goto close_i2c;
    status = open_boot_volume(image, &root);
    if (EFI_ERROR(status)) { print(err_volume); goto close_i2c; }
    status = EFI_ABORTED;

    append_text(report, &rp, "A14 EC readback v1\r\nflash_bytes=0x00100000\r\ni2c_instance=6\r\ni2c_slave=0x5b\r\nbridge_1059=0x");
    append_hex8(report, &rp, bridge_mode);
    append_text(report, &rp, "\r\njedec="); append_hex8(report, &rp, id[0]); append_char(report, &rp, ' ');
    append_hex8(report, &rp, id[1]); append_char(report, &rp, ' '); append_hex8(report, &rp, id[2]);
    append_text(report, &rp, "\r\ncrc32_pass1="); append_hex32(report, &rp, c1);
    append_text(report, &rp, "\r\ncrc32_pass2="); append_hex32(report, &rp, c2);
    append_text(report, &rp, "\r\ncrc32_pass3="); append_hex32(report, &rp, c3);
    append_text(report, &rp, "\r\npasses_identical=yes\r\nspi_commands=0x9f,0x0b\r\nspi_flash_write_commands=none\r\n");
    if (EFI_ERROR(save_file(root, n1, pass1, FLASH_SIZE)) ||
        EFI_ERROR(save_file(root, n2, pass2, FLASH_SIZE)) ||
        EFI_ERROR(save_file(root, n3, pass3, FLASH_SIZE)) ||
        EFI_ERROR(save_file(root, nr, report, rp))) {
        print(err_save); goto close_i2c;
    }
    print(msg_ok); status = EFI_SUCCESS;

close_i2c:
    if (i2c_handle) { i2c->close(i2c_handle); i2c_handle = 0; }
out:
    if (root) root->Close(root);
    if (report) bs->FreePool(report);
    if (pass3) bs->FreePool(pass3);
    if (pass2) bs->FreePool(pass2);
    if (pass1) bs->FreePool(pass1);
    if (EFI_ERROR(status)) print(msg_fail);
    return status;
}
