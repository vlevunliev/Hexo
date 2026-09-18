unit ufindcrypt;

{$mode objfpc}{$H+}

// Scans a byte range for known crypto-algorithm constants using the FindCrypt2
// signature database (ufcdb). Streams through a read callback, so it works on
// files, devices and the live edited buffer. Two match kinds:
//   non-sparse : exact contiguous little-endian array match
//   sparse     : first word32 exact, each following word32 within the next 64 B

interface

uses
  SysUtils, Classes, ufcdb;

type
  TFCReader = function(APos: Int64; var ABuf; ALen: Integer): Integer of object;

  TFCHit = record
    Offset: Int64;
    Len:    Integer;
    Algo:   string;
    Name:   string;
  end;
  TFCHits = array of TFCHit;

  TFCProgress = procedure(APos, ATotal: Int64) of object;

// AAlgo = '' scans every signature; otherwise only signatures of that algorithm.
// ACancel (if set) is polled once per chunk; when it becomes True the scan stops
// and returns the hits found so far.
function FindCrypto(AReader: TFCReader; AStart, ALen: Int64;
  out AHits: TFCHits; const AAlgo: string = ''; AProgress: TFCProgress = nil;
  ACancel: PBoolean = nil): Integer;

// Multi-algorithm variant: AAlgos lists the algorithm names to scan (empty list
// = all). Same streaming/cancel semantics.
function FindCryptoMulti(AReader: TFCReader; AStart, ALen: Int64;
  out AHits: TFCHits; AAlgos: TStrings; AProgress: TFCProgress = nil;
  ACancel: PBoolean = nil): Integer;

// distinct algorithm names, sorted (caller frees)
function FCAlgoNames: TStringList;

implementation


const
  CHUNK = 1024 * 1024;
  OVER  = 64 * 1024;      // >= longest signature (SHARK cbox 16 KB) + sparse reach
  MAXHITS = 200000;

function FCAlgoNames: TStringList;
var i: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True; Result.Duplicates := dupIgnore;
  for i := 0 to FCSigCount - 1 do Result.Add(FCSig(i).Algo);
end;

// test signature AIdx at buffer position i; returns matched byte span or 0
function MatchAt(const ABuf: array of Byte; ABufLen, i: Integer;
  const ABlob: TBytes; AIdx: Integer): Integer;
var s: TFCSig; p, k, j: Integer; found: Boolean;
begin
  Result := 0;
  s := FCSig(AIdx);
  if s.Sparse = 0 then
  begin
    if i + s.Len > ABufLen then Exit;
    if CompareByte(ABuf[i], ABlob[s.Ofs], s.Len) = 0 then Result := s.Len;
    Exit;
  end;
  // sparse: first word exact
  if i + 4 > ABufLen then Exit;
  if CompareByte(ABuf[i], ABlob[s.Ofs], 4) <> 0 then Exit;
  p := i + 4;
  for k := 1 to s.Cnt - 1 do
  begin
    found := False; j := 0;
    while j < 64 do
    begin
      if p + j + 4 > ABufLen then Break;
      if CompareByte(ABuf[p + j], ABlob[s.Ofs + k * 4], 4) = 0 then
      begin found := True; Break; end;
      Inc(j);
    end;
    if not found then Exit;
    p := p + j + 4;
  end;
  Result := p - i;
end;

function ReadFull(AReader: TFCReader; APos: Int64; var ABuf: array of Byte;
  AWant: Integer): Integer;
var got, r: Integer;
begin
  got := 0;
  while got < AWant do
  begin
    r := AReader(APos + got, ABuf[got], AWant - got);
    if r <= 0 then Break;
    Inc(got, r);
  end;
  Result := got;
end;

// core: AAlgos=nil means all; else only signatures whose Algo is in AAlgos
function FindCryptoCore(AReader: TFCReader; AStart, ALen: Int64;
  out AHits: TFCHits; AAlgos: TStrings; AProgress: TFCProgress;
  ACancel: PBoolean): Integer;
var
  buf: array of Byte;
  blob: TBytes;
  pos, endPos: Int64;
  readLen, r, testLimit, i, k, idx, span, b: Integer;
  isLast: Boolean;
  nHits: Integer;
  bucket: array[0..255] of array of Integer;   // per-call, filtered by algo
  s: TFCSig;
  useAll: Boolean;
begin
  AHits := nil; nHits := 0;
  if ALen <= 0 then Exit(0);
  blob := FCBlob;
  for b := 0 to 255 do bucket[b] := nil;
  useAll := (AAlgos = nil) or (AAlgos.Count = 0);

  // build first-byte buckets only for the selected algorithms
  for i := 0 to FCSigCount - 1 do
  begin
    s := FCSig(i);
    if (not useAll) and (AAlgos.IndexOf(s.Algo) < 0) then Continue;
    b := blob[s.Ofs];
    SetLength(bucket[b], Length(bucket[b]) + 1);
    bucket[b][High(bucket[b])] := i;
  end;

  SetLength(buf, CHUNK + OVER);
  SetLength(AHits, 1024);
  pos := AStart; endPos := AStart + ALen;

  while pos < endPos do
  begin
    if endPos - pos < CHUNK + OVER then readLen := endPos - pos else readLen := CHUNK + OVER;
    r := ReadFull(AReader, pos, buf, readLen);
    if r <= 0 then Break;
    isLast := (pos + r >= endPos) or (r < readLen);
    if isLast then testLimit := r
    else if r < CHUNK then testLimit := r
    else testLimit := CHUNK;

    for i := 0 to testLimit - 1 do
      for k := 0 to High(bucket[buf[i]]) do
      begin
        idx := bucket[buf[i]][k];
        span := MatchAt(buf, r, i, blob, idx);
        if span > 0 then
        begin
          if nHits >= Length(AHits) then SetLength(AHits, Length(AHits) * 2);
          AHits[nHits].Offset := pos + i;
          AHits[nHits].Len    := span;
          AHits[nHits].Algo   := FCSig(idx).Algo;
          AHits[nHits].Name   := FCSig(idx).Name;
          Inc(nHits);
          if nHits >= MAXHITS then begin SetLength(AHits, nHits); Exit(nHits); end;
        end;
      end;

    if Assigned(AProgress) then AProgress(pos - AStart, ALen);
    if (ACancel <> nil) and ACancel^ then Break;
    if isLast then Break;
    Inc(pos, CHUNK);
  end;

  SetLength(AHits, nHits);
  Result := nHits;
end;

function FindCrypto(AReader: TFCReader; AStart, ALen: Int64;
  out AHits: TFCHits; const AAlgo: string; AProgress: TFCProgress;
  ACancel: PBoolean): Integer;
var sl: TStringList;
begin
  if AAlgo = '' then
    Result := FindCryptoCore(AReader, AStart, ALen, AHits, nil, AProgress, ACancel)
  else
  begin
    sl := TStringList.Create;
    try
      sl.Add(AAlgo);
      Result := FindCryptoCore(AReader, AStart, ALen, AHits, sl, AProgress, ACancel);
    finally
      sl.Free;
    end;
  end;
end;

function FindCryptoMulti(AReader: TFCReader; AStart, ALen: Int64;
  out AHits: TFCHits; AAlgos: TStrings; AProgress: TFCProgress;
  ACancel: PBoolean): Integer;
begin
  Result := FindCryptoCore(AReader, AStart, ALen, AHits, AAlgos, AProgress, ACancel);
end;

end.
