unit ucng;

{$mode objfpc}{$H+}

// Minimal Windows CNG (bcrypt.dll) binding - exactly what this project calls,
// nothing else. Replaces the third-party BCrypt.pas + bcrypt_const.pas pair
// (~49 KB of Delphi headers, of which the project used maybe 3%).
//
// Declared here, and nowhere else:
//   handles / NTSTATUS / the GCM auth-info record
//   property names, chaining modes, algorithm ids, the two flags in use
//   13 entry points: OpenAlgorithmProvider, CloseAlgorithmProvider,
//     Get/SetProperty, CreateHash, HashData, FinishHash, DestroyHash,
//     GenerateSymmetricKey, Encrypt, Decrypt, DestroyKey, DeriveKeyPBKDF2
//
// Signatures are transcribed verbatim from bcrypt.h (and match the ones the
// previous binding used), so behaviour is unchanged. Windows-only by nature:
// the whole unit sits behind {$IFDEF WINDOWS} at every call site.
//
// bcrypt.dll is a Windows system component - this is still a zero-third-party-
// DLL build.

interface

{$IFDEF WINDOWS}
uses
  Windows;   // ULONG, PUCHAR, LPCWSTR

type
  NTSTATUS  = LongInt;
  ULONGLONG = QWord;

  BCRYPT_HANDLE        = Pointer;
  BCRYPT_ALG_HANDLE    = Pointer;
  BCRYPT_KEY_HANDLE    = Pointer;
  BCRYPT_HASH_HANDLE   = Pointer;

  // BCryptEncrypt/BCryptDecrypt pPaddingInfo for authenticated modes (GCM)
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = record
    cbSize:        ULONG;
    dwInfoVersion: ULONG;
    pbNonce:       PUCHAR;
    cbNonce:       ULONG;
    pbAuthData:    PUCHAR;
    cbAuthData:    ULONG;
    pbTag:         PUCHAR;
    cbTag:         ULONG;
    pbMacContext:  PUCHAR;
    cbMacContext:  ULONG;
    cbAAD:         ULONG;
    cbData:        ULONGLONG;
    dwFlags:       ULONG;
  end;
  PBCRYPT_AUTHENTICATED_CIPHER_MODE_INFO = ^BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;

const
  BCryptDll = 'bcrypt.dll';

  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION = 1;

  // --- property names (BCryptGetProperty / BCryptSetProperty) ---
  BCRYPT_OBJECT_LENGTH = 'ObjectLength';
  BCRYPT_HASH_LENGTH   = 'HashDigestLength';
  BCRYPT_CHAINING_MODE = 'ChainingMode';

  // --- chaining modes ---
  BCRYPT_CHAIN_MODE_CBC = 'ChainingModeCBC';
  BCRYPT_CHAIN_MODE_ECB = 'ChainingModeECB';
  BCRYPT_CHAIN_MODE_CFB = 'ChainingModeCFB';
  BCRYPT_CHAIN_MODE_GCM = 'ChainingModeGCM';

  // --- algorithm ids ---
  BCRYPT_AES_ALGORITHM    = 'AES';
  BCRYPT_3DES_ALGORITHM   = '3DES';
  BCRYPT_DES_ALGORITHM    = 'DES';
  BCRYPT_RC4_ALGORITHM    = 'RC4';
  BCRYPT_MD5_ALGORITHM    = 'MD5';
  BCRYPT_SHA1_ALGORITHM   = 'SHA1';
  BCRYPT_SHA256_ALGORITHM = 'SHA256';
  BCRYPT_SHA384_ALGORITHM = 'SHA384';
  BCRYPT_SHA512_ALGORITHM = 'SHA512';

  // --- flags ---
  BCRYPT_BLOCK_PADDING          = $00000001;  // BCryptEncrypt/BCryptDecrypt
  BCRYPT_ALG_HANDLE_HMAC_FLAG   = $00000008;  // BCryptOpenAlgorithmProvider

// zero the record and stamp size + version, as the bcrypt.h macro does
procedure BCRYPT_INIT_AUTH_MODE_INFO(var AInfo: BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO);

{ ---- algorithm provider ---------------------------------------------------- }

function BCryptOpenAlgorithmProvider(
  out phAlgorithm: BCRYPT_ALG_HANDLE;
  pszAlgId: LPCWSTR;
  pszImplementation: LPCWSTR;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptCloseAlgorithmProvider(
  hAlgorithm: BCRYPT_ALG_HANDLE;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptGetProperty(
  hObject: BCRYPT_HANDLE;
  pszProperty: LPCWSTR;
  pbOutput: PUCHAR;
  cbOutput: ULONG;
  out pcbResult: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptSetProperty(
  hObject: BCRYPT_HANDLE;
  pszProperty: LPCWSTR;
  pbInput: PUCHAR;
  cbInput: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

{ ---- hashing / HMAC -------------------------------------------------------- }

function BCryptCreateHash(
  hAlgorithm: BCRYPT_ALG_HANDLE;
  out phHash: BCRYPT_HASH_HANDLE;
  pbHashObject: PUCHAR;
  cbHashObject: ULONG;
  pbSecret: PUCHAR;      // HMAC key, nil for a plain digest
  cbSecret: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptHashData(
  hHash: BCRYPT_HASH_HANDLE;
  pbInput: PUCHAR;
  cbInput: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptFinishHash(
  hHash: BCRYPT_HASH_HANDLE;
  pbOutput: PUCHAR;
  cbOutput: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptDestroyHash(
  hHash: BCRYPT_HASH_HANDLE): NTSTATUS; stdcall; external BCryptDll;

{ ---- symmetric crypto ------------------------------------------------------ }

function BCryptGenerateSymmetricKey(
  hAlgorithm: BCRYPT_ALG_HANDLE;
  out phKey: BCRYPT_KEY_HANDLE;
  pbKeyObject: PUCHAR;
  cbKeyObject: ULONG;
  pbSecret: PUCHAR;
  cbSecret: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptEncrypt(
  hKey: BCRYPT_KEY_HANDLE;
  pbInput: PUCHAR;
  cbInput: ULONG;
  pPaddingInfo: Pointer;         // ^BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO for GCM
  pbIV: PUCHAR;
  cbIV: ULONG;
  pbOutput: PUCHAR;
  cbOutput: ULONG;
  out pcbResult: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptDecrypt(
  hKey: BCRYPT_KEY_HANDLE;
  pbInput: PUCHAR;
  cbInput: ULONG;
  pPaddingInfo: Pointer;
  pbIV: PUCHAR;
  cbIV: ULONG;
  pbOutput: PUCHAR;
  cbOutput: ULONG;
  out pcbResult: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

function BCryptDestroyKey(
  hKey: BCRYPT_KEY_HANDLE): NTSTATUS; stdcall; external BCryptDll;

{ ---- key derivation -------------------------------------------------------- }

function BCryptDeriveKeyPBKDF2(
  hPrf: BCRYPT_ALG_HANDLE;
  pbPassword: PUCHAR;
  cbPassword: ULONG;
  pbSalt: PUCHAR;
  cbSalt: ULONG;
  cIterations: ULONGLONG;
  pbDerivedKey: PUCHAR;
  cbDerivedKey: ULONG;
  dwFlags: ULONG): NTSTATUS; stdcall; external BCryptDll;

{$ENDIF}

implementation

{$IFDEF WINDOWS}
procedure BCRYPT_INIT_AUTH_MODE_INFO(var AInfo: BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO);
begin
  FillChar(AInfo, SizeOf(AInfo), 0);
  AInfo.cbSize := SizeOf(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO);
  AInfo.dwInfoVersion := BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO_VERSION;
end;
{$ENDIF}

end.
