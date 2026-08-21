## @file
# Minimal EDK II platform description used only to build A14ECReadback.efi.
#
# SPDX-License-Identifier: GPL-2.0-or-later
##

[Defines]
  PLATFORM_NAME                  = A14EcReadbackPkg
  PLATFORM_GUID                  = CFC43711-76EE-4EA9-A2DB-C90115EEDB04
  PLATFORM_VERSION               = 1.1
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/A14EcReadbackPkg
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = RELEASE
  SKUID_IDENTIFIER               = DEFAULT

[SkuIds]
  0|DEFAULT

[LibraryClasses]
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  StackCheckLib|MdePkg/Library/StackCheckLibNull/StackCheckLibNull.inf

[LibraryClasses.AARCH64]
  NULL|MdePkg/Library/CompilerIntrinsicsLib/CompilerIntrinsicsLib.inf

[Components]
  A14EcReadbackPkg/A14EcReadback.inf

