unit uhexcrypt;

{$mode objfpc}{$H+}

// Symmetric encrypt/decrypt via Windows CNG (BCrypt): AES, 3DES, DES, RC4 with
// ECB / CBC / CFB chaining. No padding - block ciphers require the input length
// to be a multiple of the block size (raw block operation, as a hex editor
// wants). On non-Windows the functions return an error string.

interface

uses
  SysUtils;

type
  TSymAlg  = (saAES, sa3DES, saDES, saRC4);
  TSymMode = (smECB, smCBC, smCFB);

function SymAlgName(A: TSymAlg): string;
function SymBlockSize(A: TSymAlg): Integer;      // bytes; RC4 = 1 (stream)
function SymNeedsIV(A: TSymAlg; M: TSymMode): Boolean;

// Encrypt/decrypt AInput. Returns True + AOutput on success, else False + AErr.
function SymCrypt(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;

// Same as SymCrypt but with PKCS7 padding (block ciphers only). On encrypt the
// output grows to the next block; on decrypt the padding is removed.
function SymCryptPKCS7(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;

// AES-GCM authenticated encrypt/decrypt. On encrypt returns ciphertext in
// AOutput and the tag in ATag. On decrypt ATag must hold the tag to verify;
// returns False if authentication fails.
function AesGcm(const AKey, ANonce, AInput, AAad: TBytes; AEncrypt: Boolean;
  var ATag: TBytes; out AOutput: TBytes; out AErr: string): Boolean;

// PBKDF2 (HMAC-SHA256) password -> key derivation.
function Pbkdf2(const APassword, ASalt: TBytes; AIterations, ADkLen: Integer;
  out AKey: TBytes; out AErr: string): Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Windows, ucng;
{$ENDIF}

function SymAlgName(A: TSymAlg): string;
begin
  case A of
    saAES:  Result := 'AES';
    sa3DES: Result := '3DES';
    saDES:  Result := 'DES';
    saRC4:  Result := 'RC4';
  else Result := '?';
  end;
end;

function SymBlockSize(A: TSymAlg): Integer;
begin
  case A of
    saAES:  Result := 16;
    sa3DES: Result := 8;
    saDES:  Result := 8;
    saRC4:  Result := 1;
  else Result := 1;
  end;
end;

function SymNeedsIV(A: TSymAlg; M: TSymMode): Boolean;
begin
  Result := (A <> saRC4) and (M in [smCBC, smCFB]);
end;

{$IFDEF WINDOWS}
function SymCrypt(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;
var
  hAlg: BCRYPT_ALG_HANDLE;
  hKey: BCRYPT_KEY_HANDLE;
  keyObj, ivbuf: array of Byte;
  keyObjLen, cb, outLen: ULONG;
  st: NTSTATUS;
  algId, modeStr: WideString;
  pIV: PUCHAR;
  cbIV: ULONG;
  bs: Integer;
begin
  Result := False; AErr := ''; AOutput := nil;
  hAlg := nil; hKey := nil;

  if Length(AKey) = 0 then begin AErr := 'Key is empty.'; Exit; end;
  if Length(AInput) = 0 then begin AErr := 'Nothing selected.'; Exit; end;

  bs := SymBlockSize(A);
  if (A <> saRC4) and ((Length(AInput) mod bs) <> 0) then
  begin
    AErr := Format('Input must be a multiple of %d bytes for %s (got %d).',
      [bs, SymAlgName(A), Length(AInput)]);
    Exit;
  end;

  case A of
    saAES:  algId := BCRYPT_AES_ALGORITHM;
    sa3DES: algId := BCRYPT_3DES_ALGORITHM;
    saDES:  algId := BCRYPT_DES_ALGORITHM;
    saRC4:  algId := BCRYPT_RC4_ALGORITHM;
  end;

  if BCryptOpenAlgorithmProvider(hAlg, PWideChar(algId), nil, 0) < 0 then
  begin AErr := 'Cannot open algorithm ' + SymAlgName(A); Exit; end;
  try
    keyObjLen := 0; cb := 0;
    if BCryptGetProperty(hAlg, PWideChar(WideString(BCRYPT_OBJECT_LENGTH)),
         @keyObjLen, SizeOf(keyObjLen), cb, 0) < 0 then
    begin AErr := 'GetProperty(ObjectLength) failed.'; Exit; end;
    SetLength(keyObj, keyObjLen);

    if A <> saRC4 then
    begin
      case M of
        smCBC: modeStr := BCRYPT_CHAIN_MODE_CBC;
        smECB: modeStr := BCRYPT_CHAIN_MODE_ECB;
        smCFB: modeStr := BCRYPT_CHAIN_MODE_CFB;
      end;
      if BCryptSetProperty(hAlg, PWideChar(WideString(BCRYPT_CHAINING_MODE)),
           PUCHAR(PWideChar(modeStr)), (Length(modeStr) + 1) * 2, 0) < 0 then
      begin AErr := 'SetProperty(ChainingMode) failed.'; Exit; end;
    end;

    st := BCryptGenerateSymmetricKey(hAlg, hKey, @keyObj[0], keyObjLen,
      @AKey[0], Length(AKey), 0);
    if st < 0 then
    begin AErr := Format('GenerateSymmetricKey failed (0x%.8x) - check key length.', [st]); Exit; end;
    try
      if SymNeedsIV(A, M) then
      begin
        SetLength(ivbuf, bs);
        FillChar(ivbuf[0], bs, 0);
        if Length(AIV) >= bs then Move(AIV[0], ivbuf[0], bs)
        else if Length(AIV) > 0 then Move(AIV[0], ivbuf[0], Length(AIV));
        pIV := @ivbuf[0]; cbIV := bs;
      end
      else begin pIV := nil; cbIV := 0; end;

      SetLength(AOutput, Length(AInput));
      outLen := 0;
      if AEncrypt then
        st := BCryptEncrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          @AOutput[0], Length(AOutput), outLen, 0)
      else
        st := BCryptDecrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          @AOutput[0], Length(AOutput), outLen, 0);

      if st < 0 then
      begin AErr := Format('CNG %s failed (0x%.8x).',
          [BoolToStr(AEncrypt, 'encrypt', 'decrypt'), st]); AOutput := nil; Exit; end;
      SetLength(AOutput, outLen);
      Result := True;
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

function SymCryptPKCS7(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;
var
  hAlg: BCRYPT_ALG_HANDLE;
  hKey: BCRYPT_KEY_HANDLE;
  keyObj, ivbuf: array of Byte;
  keyObjLen, cb, outLen: ULONG;
  st: NTSTATUS;
  algId, modeStr: WideString;
  pIV: PUCHAR; cbIV: ULONG;
  bs: Integer;
begin
  Result := False; AErr := ''; AOutput := nil;
  hAlg := nil; hKey := nil;
  if A = saRC4 then begin AErr := 'PKCS7 padding needs a block cipher.'; Exit; end;
  if Length(AKey) = 0 then begin AErr := 'Key is empty.'; Exit; end;
  bs := SymBlockSize(A);
  if (not AEncrypt) and ((Length(AInput) mod bs) <> 0) then
  begin AErr := Format('Ciphertext must be a multiple of %d.', [bs]); Exit; end;

  case A of
    saAES:  algId := BCRYPT_AES_ALGORITHM;
    sa3DES: algId := BCRYPT_3DES_ALGORITHM;
    saDES:  algId := BCRYPT_DES_ALGORITHM;
  end;
  if BCryptOpenAlgorithmProvider(hAlg, PWideChar(algId), nil, 0) < 0 then
  begin AErr := 'Cannot open ' + SymAlgName(A); Exit; end;
  try
    keyObjLen := 0; cb := 0;
    if BCryptGetProperty(hAlg, PWideChar(WideString(BCRYPT_OBJECT_LENGTH)),
         @keyObjLen, SizeOf(keyObjLen), cb, 0) < 0 then Exit;
    SetLength(keyObj, keyObjLen);
    case M of
      smCBC: modeStr := BCRYPT_CHAIN_MODE_CBC;
      smECB: modeStr := BCRYPT_CHAIN_MODE_ECB;
      smCFB: modeStr := BCRYPT_CHAIN_MODE_CFB;
    end;
    if BCryptSetProperty(hAlg, PWideChar(WideString(BCRYPT_CHAINING_MODE)),
         PUCHAR(PWideChar(modeStr)), (Length(modeStr) + 1) * 2, 0) < 0 then Exit;
    if BCryptGenerateSymmetricKey(hAlg, hKey, @keyObj[0], keyObjLen,
         @AKey[0], Length(AKey), 0) < 0 then
    begin AErr := 'GenerateSymmetricKey failed - check key length.'; Exit; end;
    try
      SetLength(ivbuf, bs); FillChar(ivbuf[0], bs, 0);
      if Length(AIV) >= bs then Move(AIV[0], ivbuf[0], bs)
      else if Length(AIV) > 0 then Move(AIV[0], ivbuf[0], Length(AIV));
      if M = smECB then begin pIV := nil; cbIV := 0; end
      else begin pIV := @ivbuf[0]; cbIV := bs; end;

      // first call: get needed size
      outLen := 0;
      if AEncrypt then
        st := BCryptEncrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          nil, 0, outLen, BCRYPT_BLOCK_PADDING)
      else
        st := BCryptDecrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          nil, 0, outLen, BCRYPT_BLOCK_PADDING);
      if st < 0 then begin AErr := Format('CNG size query failed (0x%.8x).', [st]); Exit; end;

      SetLength(AOutput, outLen);
      // IV was consumed by the query on some providers; reset it
      FillChar(ivbuf[0], bs, 0);
      if Length(AIV) >= bs then Move(AIV[0], ivbuf[0], bs)
      else if Length(AIV) > 0 then Move(AIV[0], ivbuf[0], Length(AIV));

      if AEncrypt then
        st := BCryptEncrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          @AOutput[0], Length(AOutput), outLen, BCRYPT_BLOCK_PADDING)
      else
        st := BCryptDecrypt(hKey, @AInput[0], Length(AInput), nil, pIV, cbIV,
          @AOutput[0], Length(AOutput), outLen, BCRYPT_BLOCK_PADDING);
      if st < 0 then
      begin AErr := Format('CNG %s failed (0x%.8x).',
          [BoolToStr(AEncrypt, 'encrypt', 'decrypt'), st]); AOutput := nil; Exit; end;
      SetLength(AOutput, outLen);
      Result := True;
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

function AesGcm(const AKey, ANonce, AInput, AAad: TBytes; AEncrypt: Boolean;
  var ATag: TBytes; out AOutput: TBytes; out AErr: string): Boolean;
var
  hAlg: BCRYPT_ALG_HANDLE;
  hKey: BCRYPT_KEY_HANDLE;
  keyObj: array of Byte;
  keyObjLen, cb, outLen: ULONG;
  st: NTSTATUS;
  modeStr: WideString;
  ai: BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO;
  tagbuf, noncebuf, aadbuf: TBytes;
const
  GCM_TAG = 16;
begin
  Result := False; AErr := ''; AOutput := nil;
  hAlg := nil; hKey := nil;
  if Length(AKey) = 0 then begin AErr := 'Key is empty.'; Exit; end;
  if Length(ANonce) = 0 then begin AErr := 'Nonce is empty (12 bytes typical).'; Exit; end;

  if BCryptOpenAlgorithmProvider(hAlg, PWideChar(WideString(BCRYPT_AES_ALGORITHM)), nil, 0) < 0 then
  begin AErr := 'Cannot open AES.'; Exit; end;
  try
    keyObjLen := 0; cb := 0;
    if BCryptGetProperty(hAlg, PWideChar(WideString(BCRYPT_OBJECT_LENGTH)),
         @keyObjLen, SizeOf(keyObjLen), cb, 0) < 0 then Exit;
    SetLength(keyObj, keyObjLen);
    modeStr := BCRYPT_CHAIN_MODE_GCM;
    if BCryptSetProperty(hAlg, PWideChar(WideString(BCRYPT_CHAINING_MODE)),
         PUCHAR(PWideChar(modeStr)), (Length(modeStr) + 1) * 2, 0) < 0 then
    begin AErr := 'Set GCM mode failed.'; Exit; end;
    if BCryptGenerateSymmetricKey(hAlg, hKey, @keyObj[0], keyObjLen,
         @AKey[0], Length(AKey), 0) < 0 then
    begin AErr := 'GenerateSymmetricKey failed - AES key must be 16/24/32 bytes.'; Exit; end;
    try
      BCRYPT_INIT_AUTH_MODE_INFO(ai);
      noncebuf := Copy(ANonce, 0, Length(ANonce));
      ai.pbNonce := @noncebuf[0]; ai.cbNonce := Length(noncebuf);
      if Length(AAad) > 0 then
      begin
        aadbuf := Copy(AAad, 0, Length(AAad));
        ai.pbAuthData := @aadbuf[0]; ai.cbAuthData := Length(aadbuf);
      end;

      SetLength(tagbuf, GCM_TAG);
      if AEncrypt then
      begin
        ai.pbTag := @tagbuf[0]; ai.cbTag := GCM_TAG;
        SetLength(AOutput, Length(AInput)); outLen := 0;
        st := BCryptEncrypt(hKey, @AInput[0], Length(AInput), @ai, nil, 0,
          @AOutput[0], Length(AOutput), outLen, 0);
        if st < 0 then begin AErr := Format('GCM encrypt failed (0x%.8x).', [st]); AOutput := nil; Exit; end;
        SetLength(AOutput, outLen);
        ATag := Copy(tagbuf, 0, GCM_TAG);
        Result := True;
      end
      else
      begin
        if Length(ATag) <> GCM_TAG then begin AErr := 'Tag must be 16 bytes.'; Exit; end;
        tagbuf := Copy(ATag, 0, GCM_TAG);
        ai.pbTag := @tagbuf[0]; ai.cbTag := GCM_TAG;
        SetLength(AOutput, Length(AInput)); outLen := 0;
        st := BCryptDecrypt(hKey, @AInput[0], Length(AInput), @ai, nil, 0,
          @AOutput[0], Length(AOutput), outLen, 0);
        if st < 0 then
        begin AErr := 'GCM auth failed - wrong key/nonce/tag or data tampered.';
          AOutput := nil; Exit; end;
        SetLength(AOutput, outLen);
        Result := True;
      end;
    finally
      BCryptDestroyKey(hKey);
    end;
  finally
    BCryptCloseAlgorithmProvider(hAlg, 0);
  end;
end;

function Pbkdf2(const APassword, ASalt: TBytes; AIterations, ADkLen: Integer;
  out AKey: TBytes; out AErr: string): Boolean;
var
  hPrf: BCRYPT_ALG_HANDLE;
  st: NTSTATUS;
  pPwd, pSalt: PUCHAR;
begin
  Result := False; AErr := ''; AKey := nil;
  if ADkLen <= 0 then begin AErr := 'Bad key length.'; Exit; end;
  if AIterations <= 0 then begin AErr := 'Iterations must be > 0.'; Exit; end;
  // HMAC-SHA256 PRF
  if BCryptOpenAlgorithmProvider(hPrf, PWideChar(WideString(BCRYPT_SHA256_ALGORITHM)),
       nil, BCRYPT_ALG_HANDLE_HMAC_FLAG) < 0 then
  begin AErr := 'Cannot open SHA256 PRF.'; Exit; end;
  try
    SetLength(AKey, ADkLen);
    if Length(APassword) > 0 then pPwd := @APassword[0] else pPwd := nil;
    if Length(ASalt) > 0 then pSalt := @ASalt[0] else pSalt := nil;
    st := BCryptDeriveKeyPBKDF2(hPrf, pPwd, Length(APassword),
      pSalt, Length(ASalt), AIterations, @AKey[0], ADkLen, 0);
    if st < 0 then begin AErr := Format('PBKDF2 failed (0x%.8x).', [st]); AKey := nil; Exit; end;
    Result := True;
  finally
    BCryptCloseAlgorithmProvider(hPrf, 0);
  end;
end;
{$ELSE}
function SymCrypt(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;
begin
  AOutput := nil; AErr := '(Windows CNG only)'; Result := False;
end;
function SymCryptPKCS7(A: TSymAlg; M: TSymMode; const AKey, AIV, AInput: TBytes;
  AEncrypt: Boolean; out AOutput: TBytes; out AErr: string): Boolean;
begin AOutput := nil; AErr := '(Windows CNG only)'; Result := False; end;
function AesGcm(const AKey, ANonce, AInput, AAad: TBytes; AEncrypt: Boolean;
  var ATag: TBytes; out AOutput: TBytes; out AErr: string): Boolean;
begin AOutput := nil; AErr := '(Windows CNG only)'; Result := False; end;
function Pbkdf2(const APassword, ASalt: TBytes; AIterations, ADkLen: Integer;
  out AKey: TBytes; out AErr: string): Boolean;
begin AKey := nil; AErr := '(Windows CNG only)'; Result := False; end;
{$ENDIF}

end.
