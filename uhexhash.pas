unit uhexhash;

{$mode objfpc}{$H+}

// Checksums / hashes over an arbitrary byte range, streamed once through a
// caller-supplied read callback (works on files, memory, devices, and the live
// edited content of THexView). HashAll computes every digest in a SINGLE pass.
//
//   CRC32  - pure Pascal (portable, always available)
//   CRC16 (CCITT/X.25), CRC64 (ECMA-182) - pure Pascal
//   MD5, SHA1, SHA256, SHA384, SHA512 - Windows CNG (BCrypt), system-only.
//   On non-Windows the CNG digests come back as "(Windows CNG only)".

interface

uses
  SysUtils;

type
  // matches TByteSource.ReadAt
  TBlockReader = function(APos: Int64; var ABuf; ALen: Integer): Integer of object;

  // called once per chunk; APos = bytes done so far, ATotal = bytes requested
  THashProgress = procedure(APos, ATotal: Int64) of object;

  THashSet = record
    CRC16, CRC32, CRC64, MD5, SHA1, SHA256, SHA384, SHA512: string;
    Processed: Int64;     // bytes actually hashed
    Complete: Boolean;    // False if cancelled or the source stopped short
    Cancelled: Boolean;
  end;

// AProgress (if set) is called once per chunk - it is the caller's hook for
// updating a progress bar and pumping messages. ACancel (if set) is polled once
// per chunk; when it becomes True the pass stops and the digests computed so far
// are returned with Complete = False.
function HashAll(AReader: TBlockReader; AStart, ALen: Int64;
  AProgress: THashProgress = nil; ACancel: PBoolean = nil): THashSet;

type
  THmacKind = (hmMD5, hmSHA1, hmSHA256, hmSHA384, hmSHA512);

// HMAC over a range with the given key. Windows CNG only; returns
// '(Windows CNG only)' elsewhere. Streamed single pass. Same progress/cancel
// semantics as HashAll; a cancelled pass returns ''.
function HmacRange(AKind: THmacKind; const AKey: TBytes;
  AReader: TBlockReader; AStart, ALen: Int64;
  AProgress: THashProgress = nil; ACancel: PBoolean = nil): string;

function HmacKindName(AKind: THmacKind): string;

implementation

{$IFDEF WINDOWS}
uses
  Windows, ucng;
{$ENDIF}

{ ---- CRC32 (IEEE, same as zlib/PNG) ---------------------------------------- }

var
  CRCTable: array[0..255] of LongWord;
  CRC16Table: array[0..255] of Word;
  CRC64Table: array[0..255] of QWord;
  CRCReady: Boolean = False;

procedure InitCRC;
var i, j: Integer; c: LongWord; w: Word; q: QWord;
const
  POLY16 = $1021;              // CRC-16/CCITT (XModem family), MSB-first
  POLY64 = QWord($42F0E1EBA9EA3693);   // CRC-64/ECMA-182, MSB-first
begin
  for i := 0 to 255 do
  begin
    c := i;
    for j := 0 to 7 do
      if (c and 1) <> 0 then c := $EDB88320 xor (c shr 1) else c := c shr 1;
    CRCTable[i] := c;
  end;
  // CRC-16/CCITT (poly 0x1021, MSB-first, init 0xFFFF, no reflect)
  for i := 0 to 255 do
  begin
    w := Word(i shl 8);
    for j := 0 to 7 do
      if (w and $8000) <> 0 then w := Word((w shl 1) xor POLY16) else w := Word(w shl 1);
    CRC16Table[i] := w;
  end;
  // CRC-64/ECMA-182 (poly 0x42F0E1EBA9EA3693, MSB-first, init 0, no reflect)
  for i := 0 to 255 do
  begin
    q := QWord(i) shl 56;
    for j := 0 to 7 do
      if (q and QWord($8000000000000000)) <> 0 then q := (q shl 1) xor POLY64 else q := q shl 1;
    CRC64Table[i] := q;
  end;
  CRCReady := True;
end;

{ ---- CNG per-algorithm context --------------------------------------------- }

{$IFDEF WINDOWS}
type
  TCng = record
    hAlg: BCRYPT_ALG_HANDLE;
    hHash: BCRYPT_HASH_HANDLE;
    hashObj, digest: array of Byte;
    hashLen: ULONG;
    ok: Boolean;
  end;

function CngInit(const AAlgId: WideString): TCng;
var objLen, cb: ULONG;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ok := False;
  if BCryptOpenAlgorithmProvider(Result.hAlg, PWideChar(AAlgId), nil, 0) < 0 then Exit;
  objLen := 0; cb := 0;
  if BCryptGetProperty(Result.hAlg, PWideChar(WideString(BCRYPT_OBJECT_LENGTH)),
       @objLen, SizeOf(objLen), cb, 0) < 0 then Exit;
  Result.hashLen := 0;
  if BCryptGetProperty(Result.hAlg, PWideChar(WideString(BCRYPT_HASH_LENGTH)),
       @Result.hashLen, SizeOf(Result.hashLen), cb, 0) < 0 then Exit;
  SetLength(Result.hashObj, objLen);
  SetLength(Result.digest, Result.hashLen);
  if BCryptCreateHash(Result.hAlg, Result.hHash, @Result.hashObj[0], objLen,
       nil, 0, 0) < 0 then Exit;
  Result.ok := True;
end;

procedure CngUpdate(var C: TCng; const ABuf; ALen: Integer);
begin
  if C.ok then
    if BCryptHashData(C.hHash, PUCHAR(@ABuf), ALen, 0) < 0 then C.ok := False;
end;

function CngFinal(var C: TCng): string;
var i: Integer;
begin
  Result := '(error)';
  if C.ok and (BCryptFinishHash(C.hHash, @C.digest[0], C.hashLen, 0) >= 0) then
  begin
    Result := '';
    for i := 0 to High(C.digest) do Result := Result + IntToHex(C.digest[i], 2);
  end;
  if C.hHash <> nil then BCryptDestroyHash(C.hHash);
  if C.hAlg <> nil then BCryptCloseAlgorithmProvider(C.hAlg, 0);
end;
{$ENDIF}

{ ---- single-pass multi-hash ------------------------------------------------ }

const
  HASH_CHUNK = 1024 * 1024;   // 1 MB - far fewer syscalls on raw devices

function HashAll(AReader: TBlockReader; AStart, ALen: Int64;
  AProgress: THashProgress; ACancel: PBoolean): THashSet;
var
  buf: array of Byte;
  pos, remaining, done: Int64;
  chunk, r, i: Integer;
  crc: LongWord;
  crc16: Word;
  crc64: QWord;
  {$IFDEF WINDOWS}
  md5, sha1, sha256, sha384, sha512: TCng;
  {$ENDIF}
begin
  if not CRCReady then InitCRC;
  crc := $FFFFFFFF;
  crc16 := $FFFF;
  crc64 := 0;
  done := 0;
  Result.Processed := 0;
  Result.Complete := False;
  Result.Cancelled := False;
  SetLength(buf, HASH_CHUNK);
  {$IFDEF WINDOWS}
  md5    := CngInit(BCRYPT_MD5_ALGORITHM);
  sha1   := CngInit(BCRYPT_SHA1_ALGORITHM);
  sha256 := CngInit(BCRYPT_SHA256_ALGORITHM);
  sha384 := CngInit(BCRYPT_SHA384_ALGORITHM);
  sha512 := CngInit(BCRYPT_SHA512_ALGORITHM);
  {$ENDIF}

  pos := AStart; remaining := ALen;
  if Assigned(AProgress) then AProgress(0, ALen);
  while remaining > 0 do
  begin
    if remaining > HASH_CHUNK then chunk := HASH_CHUNK else chunk := Integer(remaining);
    r := AReader(pos, buf[0], chunk);
    if r <= 0 then Break;
    for i := 0 to r - 1 do
    begin
      crc   := CRCTable[(crc xor buf[i]) and $FF] xor (crc shr 8);
      crc16 := Word((crc16 shl 8) xor CRC16Table[((crc16 shr 8) xor buf[i]) and $FF]);
      crc64 := CRC64Table[((crc64 shr 56) xor buf[i]) and $FF] xor (crc64 shl 8);
    end;
    {$IFDEF WINDOWS}
    CngUpdate(md5, buf[0], r);    CngUpdate(sha1, buf[0], r);
    CngUpdate(sha256, buf[0], r); CngUpdate(sha384, buf[0], r);
    CngUpdate(sha512, buf[0], r);
    {$ENDIF}
    Inc(pos, r); Dec(remaining, r); Inc(done, r);
    if Assigned(AProgress) then AProgress(done, ALen);
    if (ACancel <> nil) and ACancel^ then
    begin
      Result.Cancelled := True;
      Break;
    end;
  end;
  Result.Processed := done;
  Result.Complete := (remaining = 0);

  Result.CRC16 := IntToHex(crc16, 4);
  Result.CRC32 := IntToHex(crc xor $FFFFFFFF, 8);
  Result.CRC64 := IntToHex(crc64, 16);
  {$IFDEF WINDOWS}
  Result.MD5    := CngFinal(md5);
  Result.SHA1   := CngFinal(sha1);
  Result.SHA256 := CngFinal(sha256);
  Result.SHA384 := CngFinal(sha384);
  Result.SHA512 := CngFinal(sha512);
  {$ELSE}
  Result.MD5 := '(Windows CNG only)';   Result.SHA1 := '(Windows CNG only)';
  Result.SHA256 := '(Windows CNG only)'; Result.SHA384 := '(Windows CNG only)';
  Result.SHA512 := '(Windows CNG only)';
  {$ENDIF}
end;

function HmacKindName(AKind: THmacKind): string;
begin
  case AKind of
    hmMD5:    Result := 'HMAC-MD5';
    hmSHA1:   Result := 'HMAC-SHA1';
    hmSHA256: Result := 'HMAC-SHA256';
    hmSHA384: Result := 'HMAC-SHA384';
    hmSHA512: Result := 'HMAC-SHA512';
  else Result := 'HMAC';
  end;
end;

{$IFDEF WINDOWS}
function HmacRange(AKind: THmacKind; const AKey: TBytes;
  AReader: TBlockReader; AStart, ALen: Int64;
  AProgress: THashProgress; ACancel: PBoolean): string;
var
  hAlg: BCRYPT_ALG_HANDLE;
  hHash: BCRYPT_HASH_HANDLE;
  objLen, hashLen, cb: ULONG;
  hashObj, digest, buf: array of Byte;
  pos, remaining, done: Int64;
  chunk, r, i: Integer;
  algId: WideString;
  pKey: PUCHAR; cbKey: ULONG;
begin
  Result := '';
  hAlg := nil; hHash := nil;
  case AKind of
    hmMD5:    algId := BCRYPT_MD5_ALGORITHM;
    hmSHA1:   algId := BCRYPT_SHA1_ALGORITHM;
    hmSHA256: algId := BCRYPT_SHA256_ALGORITHM;
    hmSHA384: algId := BCRYPT_SHA384_ALGORITHM;
    hmSHA512: algId := BCRYPT_SHA512_ALGORITHM;
  end;
  // open with HMAC flag
  if BCryptOpenAlgorithmProvider(hAlg, PWideChar(algId), nil,
       BCRYPT_ALG_HANDLE_HMAC_FLAG) < 0 then Exit;
  try
    objLen := 0; cb := 0;
    if BCryptGetProperty(hAlg, PWideChar(WideString(BCRYPT_OBJECT_LENGTH)),
         @objLen, SizeOf(objLen), cb, 0) < 0 then Exit;
    hashLen := 0;
    if BCryptGetProperty(hAlg, PWideChar(WideString(BCRYPT_HASH_LENGTH)),
         @hashLen, SizeOf(hashLen), cb, 0) < 0 then Exit;
    SetLength(hashObj, objLen);
    SetLength(digest, hashLen);
    if Length(AKey) > 0 then begin pKey := @AKey[0]; cbKey := Length(AKey); end
    else begin pKey := nil; cbKey := 0; end;
    // pass the key as the hash secret
    if BCryptCreateHash(hAlg, hHash, @hashObj[0], objLen, pKey, cbKey, 0) < 0 then Exit;
    try
      pos := AStart; remaining := ALen; done := 0;
      SetLength(buf, HASH_CHUNK);
      if Assigned(AProgress) then AProgress(0, ALen);
      while remaining > 0 do
      begin
        if remaining > HASH_CHUNK then chunk := HASH_CHUNK else chunk := Integer(remaining);
        r := AReader(pos, buf[0], chunk);
        if r <= 0 then Break;
        if BCryptHashData(hHash, @buf[0], r, 0) < 0 then Exit;
        Inc(pos, r); Dec(remaining, r); Inc(done, r);
        if Assigned(AProgress) then AProgress(done, ALen);
        if (ACancel <> nil) and ACancel^ then Exit;   // Result stays ''
      end;
      if BCryptFinishHash(hHash, @digest[0], hashLen, 0) < 0 then Exit;
      Result := '';
      for i := 0 to High(digest) do Result := Result + IntToHex(digest[i], 2);
    finally
      BCryptDestroyHash(hHash);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;
{$ELSE}
function HmacRange(AKind: THmacKind; const AKey: TBytes;
  AReader: TBlockReader; AStart, ALen: Int64;
  AProgress: THashProgress; ACancel: PBoolean): string;
begin
  Result := '(Windows CNG only)';
end;
{$ENDIF}

end.
