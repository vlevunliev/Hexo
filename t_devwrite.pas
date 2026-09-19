program t_devwrite;
{$mode objfpc}{$H+}
// headless test of raw-device write-back (uses a regular file as the "device",
// so the POSIX branch of TRawDeviceByteSource exercises the same code path):
//   - read-only source refuses to write at all
//   - FixedLength blocks insert / delete and clips overwrite at the end
//   - ModifiedRanges reports exactly the edited runs, adjacent ones merged
//   - CommitToBacking patches ONLY those bytes, leaving neighbours intact,
//     including edits that straddle a 512-byte sector boundary
//   - after the commit the image is clean and undo history is gone
uses Interfaces, SysUtils, Classes, uHexView;

type
  // a source that ACCEPTS writes and quietly keeps the old bytes - exactly how
  // a write-protected stick (or Windows dropping a cached raw write) behaves
  TSilentDropSource = class(TByteSource)
  private
    FData: array of Byte;
  public
    Writes: Integer;
    constructor Create(const AData: TBytes);
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    function CanWrite: Boolean; override;
    function WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer; override;
  end;

  // the nastier one: it ACKS the write and serves it back from its own cache,
  // while the media keeps the old bytes - a failing/counterfeit flash drive.
  // A plain read-back cannot see through this; VerifyReadAt must.
  TLyingCacheSource = class(TByteSource)
  private
    FMedia: array of Byte;      // what is really on the platter
    FCache: array of Byte;      // what the controller pretends is there
  public
    constructor Create(const AData: TBytes);
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    function VerifyReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    function CanWrite: Boolean; override;
    function WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer; override;
  end;


constructor TSilentDropSource.Create(const AData: TBytes);
begin
  inherited Create;
  SetLength(FData, Length(AData));
  if Length(AData) > 0 then Move(AData[0], FData[0], Length(AData));
end;

function TSilentDropSource.Size: TFileOfs;
begin Result := Length(FData); end;

function TSilentDropSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) or (APos >= Length(FData)) then Exit;
  if APos + ALen > Length(FData) then ALen := Length(FData) - APos;
  Move(FData[APos], ABuf, ALen);
  Result := ALen;
end;

function TSilentDropSource.CanWrite: Boolean;
begin Result := True; end;

function TSilentDropSource.WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer;
begin
  Inc(Writes);
  Result := ALen;          // "success" - and not a byte changes
end;

constructor TLyingCacheSource.Create(const AData: TBytes);
begin
  inherited Create;
  SetLength(FMedia, Length(AData));
  SetLength(FCache, Length(AData));
  if Length(AData) > 0 then
  begin
    Move(AData[0], FMedia[0], Length(AData));
    Move(AData[0], FCache[0], Length(AData));
  end;
end;

function TLyingCacheSource.Size: TFileOfs;
begin Result := Length(FMedia); end;

function TLyingCacheSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) or (APos >= Length(FCache)) then Exit;
  if APos + ALen > Length(FCache) then ALen := Length(FCache) - APos;
  Move(FCache[APos], ABuf, ALen);           // the cache answers
  Result := ALen;
end;

function TLyingCacheSource.VerifyReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) or (APos >= Length(FMedia)) then Exit;
  if APos + ALen > Length(FMedia) then ALen := Length(FMedia) - APos;
  Move(FMedia[APos], ABuf, ALen);           // a fresh handle sees the truth
  Result := ALen;
end;

function TLyingCacheSource.CanWrite: Boolean;
begin Result := True; end;

function TLyingCacheSource.WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer;
begin
  if (APos >= 0) and (APos + ALen <= Length(FCache)) then
    Move(ABuf, FCache[APos], ALen);         // only the cache changes
  Result := ALen;
end;

const
  SZ = 4 * 1024 * 1024;

var
  fails: Integer = 0;
  path: string;

procedure Chk(const AName: string; AOk: Boolean);
begin
  if AOk then WriteLn('ok   ', AName)
  else begin WriteLn('FAIL ', AName); Inc(fails); end;
end;

procedure ChkI(const AName: string; AGot, AWant: Int64);
begin
  if AGot = AWant then WriteLn('ok   ', AName, ' = ', AGot)
  else begin WriteLn('FAIL ', AName, ' = ', AGot, ' (want ', AWant, ')'); Inc(fails); end;
end;

function MakeImage: TBytes;
var i: Integer;
begin
  SetLength(Result, SZ);
  for i := 0 to SZ - 1 do Result[i] := Byte((i * 31 + (i shr 9)) and $FF);
end;

procedure WriteFileBytes(const AName: string; const AData: TBytes);
var fs: TFileStream;
begin
  fs := TFileStream.Create(AName, fmCreate);
  try fs.WriteBuffer(AData[0], Length(AData)); finally fs.Free; end;
end;

function ReadFileBytes(const AName: string): TBytes;
var fs: TFileStream;
begin
  fs := TFileStream.Create(AName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally fs.Free; end;
end;

var
  orig, expect, back: TBytes;
  dev: TRawDeviceByteSource;
  ed: TEditByteSource;
  r: TModRanges;
  patchA, patchB, patchC, big: TBytes;
  i, diff, firstDiff: Integer;
  b: Byte;
  drop: TSilentDropSource;
  liar: TLyingCacheSource;
  caught: Boolean;
  vofs: Int64;
begin
  path := GetTempDir + 'hexo_fake_device.img';
  orig := MakeImage;
  WriteFileBytes(path, orig);

  { ---- 1. read-only source writes nothing ---------------------------------- }
  dev := TRawDeviceByteSource.Create(path, False);
  try
    Chk('read-only: CanWrite is False', not dev.CanWrite);
    b := $FF;
    ChkI('read-only: WriteAt returns 0', dev.WriteAt(0, b, 1), 0);
    ed := TEditByteSource.Create(dev, False);
    try
      Chk('read-only: CanCommit is False', not ed.CanCommit);
    finally ed.Free; end;
  finally dev.Free; end;
  back := ReadFileBytes(path);
  Chk('read-only: image untouched', CompareMem(@orig[0], @back[0], SZ));

  { ---- 2. writable + fixed length ------------------------------------------ }
  dev := TRawDeviceByteSource.Create(path, True);
  ed := TEditByteSource.Create(dev, True);
  try
    ed.FixedLength := True;
    Chk('writable: CanWrite', dev.CanWrite);
    Chk('writable: CanCommit', ed.CanCommit);
    ChkI('size', ed.Size, SZ);

    // insert / delete must be refused outright
    b := $AA;
    ed.InsertData(100, b, 1);
    ChkI('insert refused (size)', ed.Size, SZ);
    Chk('insert refused (not modified)', not ed.Modified);
    ed.DeleteRange(100, 10);
    ChkI('delete refused (size)', ed.Size, SZ);
    Chk('delete refused (not modified)', not ed.Modified);

    // overwrite running past the end is clipped, never grows the image
    SetLength(big, 64);
    for i := 0 to 63 do big[i] := $5A;
    ed.Overwrite(SZ - 16, big[0], 64);
    ChkI('overwrite past end clipped (size)', ed.Size, SZ);

    expect := Copy(orig, 0, SZ);
    for i := 0 to 15 do expect[SZ - 16 + i] := $5A;

    // A: sector-aligned, at offset 0
    SetLength(patchA, 4);
    patchA[0] := $DE; patchA[1] := $AD; patchA[2] := $BE; patchA[3] := $EF;
    ed.Overwrite(0, patchA[0], 4);
    for i := 0 to 3 do expect[i] := patchA[i];

    // B: mid-sector, nowhere near a boundary
    SetLength(patchB, 3);
    patchB[0] := $11; patchB[1] := $22; patchB[2] := $33;
    ed.Overwrite(1000, patchB[0], 3);
    for i := 0 to 2 do expect[1000 + i] := patchB[i];

    // C: straddles the 512-byte sector boundary at 2048
    SetLength(patchC, 8);
    for i := 0 to 7 do patchC[i] := Byte($90 + i);
    ed.Overwrite(2044, patchC[0], 8);
    for i := 0 to 7 do expect[2044 + i] := patchC[i];

    Chk('modified flag set', ed.Modified);
    Chk('undo available before commit', ed.CanUndo);

    r := ed.ModifiedRanges;
    ChkI('modified ranges', Length(r), 4);
    if Length(r) = 4 then
    begin
      ChkI('range 0 start', r[0].Start, 0);     ChkI('range 0 len', r[0].Len, 4);
      ChkI('range 1 start', r[1].Start, 1000);  ChkI('range 1 len', r[1].Len, 3);
      ChkI('range 2 start', r[2].Start, 2044);  ChkI('range 2 len', r[2].Len, 8);
      ChkI('range 3 start', r[3].Start, SZ-16); ChkI('range 3 len', r[3].Len, 16);
    end;
    ChkI('modified byte count', ed.ModifiedByteCount, 4 + 3 + 8 + 16);

    // nothing may have reached the file yet
    back := ReadFileBytes(path);
    Chk('before commit: file untouched', CompareMem(@orig[0], @back[0], SZ));

    ed.CommitToBacking;

    Chk('after commit: not modified', not ed.Modified);
    Chk('after commit: undo cleared', not ed.CanUndo);
    ChkI('after commit: size', ed.Size, SZ);
    ChkI('after commit: no modified ranges', Length(ed.ModifiedRanges), 0);
  finally
    ed.Free;    // owns and frees the device source
  end;

  { ---- 3. the bytes on disk are exactly the expected image ------------------ }
  back := ReadFileBytes(path);
  ChkI('file size unchanged', Length(back), SZ);
  diff := 0; firstDiff := -1;
  for i := 0 to SZ - 1 do
    if back[i] <> expect[i] then
    begin
      Inc(diff);
      if firstDiff < 0 then firstDiff := i;
    end;
  if diff = 0 then WriteLn('ok   every byte matches the expected image')
  else
  begin
    WriteLn('FAIL ', diff, ' bytes differ, first at 0x', IntToHex(firstDiff, 8));
    Inc(fails);
  end;

  // and specifically: the sectors around each patch kept their original bytes
  Chk('byte before patch B intact', back[999] = orig[999]);
  Chk('byte after  patch B intact', back[1003] = orig[1003]);
  Chk('byte before patch C intact', back[2043] = orig[2043]);
  Chk('byte after  patch C intact', back[2052] = orig[2052]);
  Chk('far sector intact', CompareMem(@orig[1024 * 1024], @back[1024 * 1024], 4096));

  { ---- 4. a device that swallows writes must NOT report success ------------ }
  drop := TSilentDropSource.Create(orig);
  ed := TEditByteSource.Create(drop, True);
  try
    ed.FixedLength := True;
    SetLength(patchA, 4);
    patchA[0] := $DE; patchA[1] := $AD; patchA[2] := $BE; patchA[3] := $EF;
    ed.Overwrite(2048, patchA[0], 4);
    caught := False; vofs := -1;
    try
      ed.CommitToBacking;
    except
      on E: EHexVerify do begin caught := True; vofs := E.Offset; end;
    end;
    Chk('silent drop -> commit raises EHexVerify', caught);
    ChkI('silent drop -> reported offset', vofs, 2048);
    Chk('silent drop -> write was attempted', drop.Writes > 0);
    Chk('silent drop -> edits kept (still modified)', ed.Modified);
    ChkI('silent drop -> ranges kept', Length(ed.ModifiedRanges), 1);
    Chk('silent drop -> undo still available', ed.CanUndo);
  finally
    ed.Free;
  end;

  { ---- 5. a device that caches the write but never stores it -------------- }
  liar := TLyingCacheSource.Create(orig);
  ed := TEditByteSource.Create(liar, True);
  try
    ed.FixedLength := True;
    SetLength(patchA, 4);
    patchA[0] := $DE; patchA[1] := $AD; patchA[2] := $BE; patchA[3] := $EF;
    ed.Overwrite(4096, patchA[0], 4);
    // a plain read-back is fooled - this is what the old check did
    b := 0;
    liar.WriteAt(4096, patchA[0], 4);
    ed.ReadAt(4096, b, 1);
    Chk('lying cache -> a plain read is fooled', b = $DE);
    caught := False; vofs := -1;
    try
      ed.CommitToBacking;
    except
      on E: EHexVerify do begin caught := True; vofs := E.Offset; end;
    end;
    Chk('lying cache -> commit still raises EHexVerify', caught);
    ChkI('lying cache -> reported offset', vofs, 4096);
    Chk('lying cache -> edits kept', ed.Modified);
  finally
    ed.Free;
  end;

  DeleteFile(path);
  WriteLn;
  if fails = 0 then WriteLn('ALL OK') else WriteLn(fails, ' FAILURES');
  Halt(Ord(fails <> 0));
end.
