#ifndef A14_UEFI_MIN_H
#define A14_UEFI_MIN_H

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef unsigned long long UINTN;
typedef unsigned long long EFI_STATUS;
typedef void *EFI_HANDLE;
typedef void VOID;
typedef UINT16 CHAR16;

#define EFIAPI
#define EFI_SUCCESS 0
#define EFI_ERROR(s) (((s) >> 63) != 0)
#define EFI_BUFFER_TOO_SMALL (0x8000000000000005ULL)
#define EFI_NOT_FOUND        (0x800000000000000eULL)
#define EFI_DEVICE_ERROR     (0x8000000000000007ULL)
#define EFI_ABORTED          (0x8000000000000015ULL)
#define EfiLoaderData 2
#define EFI_FILE_MODE_READ   0x0000000000000001ULL
#define EFI_FILE_MODE_WRITE  0x0000000000000002ULL
#define EFI_FILE_MODE_CREATE 0x8000000000000000ULL

typedef struct {
    UINT32 Data1;
    UINT16 Data2;
    UINT16 Data3;
    UINT8 Data4[8];
} EFI_GUID;

typedef struct {
    UINT64 Signature;
    UINT32 Revision;
    UINT32 HeaderSize;
    UINT32 CRC32;
    UINT32 Reserved;
} EFI_TABLE_HEADER;

typedef struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
typedef EFI_STATUS (EFIAPI *EFI_TEXT_STRING)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *, CHAR16 *);
struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    VOID *Reset;
    EFI_TEXT_STRING OutputString;
    VOID *TestString;
    VOID *QueryMode;
    VOID *SetMode;
    VOID *SetAttribute;
    VOID *ClearScreen;
    VOID *SetCursorPosition;
    VOID *EnableCursor;
    VOID *Mode;
};

typedef struct EFI_BOOT_SERVICES EFI_BOOT_SERVICES;
typedef EFI_STATUS (EFIAPI *EFI_ALLOCATE_POOL)(UINT32, UINTN, VOID **);
typedef EFI_STATUS (EFIAPI *EFI_FREE_POOL)(VOID *);
typedef EFI_STATUS (EFIAPI *EFI_HANDLE_PROTOCOL)(EFI_HANDLE, EFI_GUID *, VOID **);
typedef EFI_STATUS (EFIAPI *EFI_LOCATE_PROTOCOL)(EFI_GUID *, VOID *, VOID **);

struct EFI_BOOT_SERVICES {
    EFI_TABLE_HEADER Hdr;
    VOID *RaiseTPL;
    VOID *RestoreTPL;
    VOID *AllocatePages;
    VOID *FreePages;
    VOID *GetMemoryMap;
    EFI_ALLOCATE_POOL AllocatePool;
    EFI_FREE_POOL FreePool;
    VOID *CreateEvent;
    VOID *SetTimer;
    VOID *WaitForEvent;
    VOID *SignalEvent;
    VOID *CloseEvent;
    VOID *CheckEvent;
    VOID *InstallProtocolInterface;
    VOID *ReinstallProtocolInterface;
    VOID *UninstallProtocolInterface;
    EFI_HANDLE_PROTOCOL HandleProtocol;
    VOID *Reserved;
    VOID *RegisterProtocolNotify;
    VOID *LocateHandle;
    VOID *LocateDevicePath;
    VOID *InstallConfigurationTable;
    VOID *LoadImage;
    VOID *StartImage;
    VOID *Exit;
    VOID *UnloadImage;
    VOID *ExitBootServices;
    VOID *GetNextMonotonicCount;
    VOID *Stall;
    VOID *SetWatchdogTimer;
    VOID *ConnectController;
    VOID *DisconnectController;
    VOID *OpenProtocol;
    VOID *CloseProtocol;
    VOID *OpenProtocolInformation;
    VOID *ProtocolsPerHandle;
    VOID *LocateHandleBuffer;
    EFI_LOCATE_PROTOCOL LocateProtocol;
    VOID *InstallMultipleProtocolInterfaces;
    VOID *UninstallMultipleProtocolInterfaces;
    VOID *CalculateCrc32;
    VOID *CopyMem;
    VOID *SetMem;
    VOID *CreateEventEx;
};

typedef struct {
    EFI_TABLE_HEADER Hdr;
    CHAR16 *FirmwareVendor;
    UINT32 FirmwareRevision;
    UINT32 Pad;
    EFI_HANDLE ConsoleInHandle;
    VOID *ConIn;
    EFI_HANDLE ConsoleOutHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE StandardErrorHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
    VOID *RuntimeServices;
    EFI_BOOT_SERVICES *BootServices;
    UINTN NumberOfTableEntries;
    VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

typedef struct {
    UINT32 Revision;
    UINT32 Pad;
    EFI_HANDLE ParentHandle;
    EFI_SYSTEM_TABLE *SystemTable;
    EFI_HANDLE DeviceHandle;
    VOID *FilePath;
    VOID *Reserved;
    UINT32 LoadOptionsSize;
    UINT32 Pad2;
    VOID *LoadOptions;
    VOID *ImageBase;
    UINT64 ImageSize;
    UINT32 ImageCodeType;
    UINT32 ImageDataType;
    EFI_STATUS (EFIAPI *Unload)(EFI_HANDLE);
} EFI_LOADED_IMAGE_PROTOCOL;

typedef struct EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
typedef EFI_STATUS (EFIAPI *EFI_FILE_OPEN)(EFI_FILE_PROTOCOL *, EFI_FILE_PROTOCOL **,
                                           CHAR16 *, UINT64, UINT64);
typedef EFI_STATUS (EFIAPI *EFI_FILE_CLOSE)(EFI_FILE_PROTOCOL *);
typedef EFI_STATUS (EFIAPI *EFI_FILE_WRITE)(EFI_FILE_PROTOCOL *, UINTN *, VOID *);
struct EFI_FILE_PROTOCOL {
    UINT64 Revision;
    EFI_FILE_OPEN Open;
    EFI_FILE_CLOSE Close;
    VOID *Delete;
    VOID *Read;
    EFI_FILE_WRITE Write;
    VOID *GetPosition;
    VOID *SetPosition;
    VOID *GetInfo;
    VOID *SetInfo;
    VOID *Flush;
    VOID *OpenEx;
    VOID *ReadEx;
    VOID *WriteEx;
    VOID *FlushEx;
};

typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;
typedef EFI_STATUS (EFIAPI *EFI_OPEN_VOLUME)(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *, EFI_FILE_PROTOCOL **);
struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
    UINT64 Revision;
    EFI_OPEN_VOLUME OpenVolume;
};

#endif
