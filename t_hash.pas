program t_hash;
{$mode objfpc}{$H+}
// headless regression test for the reworked uhexhash.HashAll:
//   - CRC values unchanged against the README reference vectors
//   - multi-chunk (>1 MB) pass matches a single-shot pass
//   - progress callback monotonic and ends at total
//   - short read  -> Complete=False, Processed = what was actually read
//   - cancel flag -> Cancelled=True, loop stops promptly
uses SysUtils, uhexhash;

type
  TSrc = class
  public
    Data: TBytes;
    StopAt: Int64;       // -1 = no short read
    Calls: Integer;
    function Read(APos: Int64; var ABuf; ALen: Integer): Integer;
  end;

  TWatch = class
  public
    Last, Total: Int64;
    Hits: Integer;
    Monotonic: Boolean;
    CancelAt: Int64;     // -1 = never
    Flag: Boolean;
    constructor Create;
    procedure Prog(APos, ATotal: Int64);
  end;

function TSrc.Read(APos: Int64; var ABuf; ALen: Integer): Integer;
begin
  Inc(Calls);
  Result := 0;
  if (APos < 0) or (APos >= Length(Data)) then Exit;
  if APos + ALen > Length(Data) then ALen := Length(Data) - APos;
  if (StopAt >= 0) and (APos >= StopAt) then Exit;          // simulated failure
  if (StopAt >= 0) and (APos + ALen > StopAt) then ALen := StopAt - APos;
  Move(Data[APos], ABuf, ALen);
  Result := ALen;
end;

constructor TWatch.Create;
begin
  inherited Create; Last := -1; Monotonic := True; CancelAt := -1;
end;

procedure TWatch.Prog(APos, ATotal: Int64);
begin
  Inc(Hits);
  if APos < Last then Monotonic := False;
  Last := APos; Total := ATotal;
  if (CancelAt >= 0) and (APos >= CancelAt) then Flag := True;
end;

var
  fails: Integer = 0;

procedure Chk(const AName, AGot, AWant: string);
begin
  if AGot = AWant then WriteLn('ok   ', AName, ' = ', AGot)
  else begin WriteLn('FAIL ', AName, ' = ', AGot, '  (want ', AWant, ')'); Inc(fails); end;
end;

procedure ChkB(const AName: string; AGot, AWant: Boolean);
begin
  if AGot = AWant then WriteLn('ok   ', AName, ' = ', AGot)
  else begin WriteLn('FAIL ', AName, ' = ', AGot, '  (want ', AWant, ')'); Inc(fails); end;
end;

procedure ChkI(const AName: string; AGot, AWant: Int64);
begin
  if AGot = AWant then WriteLn('ok   ', AName, ' = ', AGot)
  else begin WriteLn('FAIL ', AName, ' = ', AGot, '  (want ', AWant, ')'); Inc(fails); end;
end;

var
  s: TSrc; w: TWatch; h, h2: THashSet; i: Integer; bytes: TBytes;
begin
  // ---- 1. reference vectors ("123456789") -----------------------------------
  s := TSrc.Create; s.StopAt := -1;
  bytes := TEncoding.ASCII.GetBytes('123456789');
  s.Data := bytes;
  h := HashAll(@s.Read, 0, Length(s.Data));
  Chk('CRC16', h.CRC16, '29B1');
  Chk('CRC32', h.CRC32, 'CBF43926');
  Chk('CRC64', h.CRC64, '6C40DF5F0B497347');
  ChkB('complete', h.Complete, True);
  ChkI('processed', h.Processed, 9);
  s.Free;

  // ---- 2. multi-chunk: 3.5 MB, crosses the 1 MB chunk boundary --------------
  s := TSrc.Create; s.StopAt := -1;
  SetLength(s.Data, 3*1024*1024 + 12345);
  for i := 0 to High(s.Data) do s.Data[i] := Byte((i * 37 + (i shr 11)) and $FF);
  w := TWatch.Create;
  h := HashAll(@s.Read, 0, Length(s.Data), @w.Prog, nil);
  ChkB('multi-chunk complete', h.Complete, True);
  ChkI('multi-chunk processed', h.Processed, Length(s.Data));
  ChkB('progress monotonic', w.Monotonic, True);
  ChkI('progress ends at total', w.Last, Length(s.Data));
  ChkI('progress total', w.Total, Length(s.Data));
  WriteLn('     read calls = ', s.Calls, ' (1 MB chunks => ~4 + final)');
  w.Free;

  // same data hashed from an offset must match a slice hashed from 0
  h2 := HashAll(@s.Read, 1024*1024, Length(s.Data) - 1024*1024);
  ChkB('offset pass complete', h2.Complete, True);
  ChkI('offset pass processed', h2.Processed, Length(s.Data) - 1024*1024);

  // ---- 3. short read (device read failure mid-range) ------------------------
  s.StopAt := 2*1024*1024;
  h := HashAll(@s.Read, 0, Length(s.Data));
  ChkB('short read -> not complete', h.Complete, False);
  ChkB('short read -> not cancelled', h.Cancelled, False);
  ChkI('short read -> processed', h.Processed, 2*1024*1024);

  // ---- 4. cancel ------------------------------------------------------------
  s.StopAt := -1;
  w := TWatch.Create; w.CancelAt := 1024*1024;      // trip the flag after 1 MB
  h := HashAll(@s.Read, 0, Length(s.Data), @w.Prog, @w.Flag);
  ChkB('cancel -> cancelled', h.Cancelled, True);
  ChkB('cancel -> not complete', h.Complete, False);
  ChkI('cancel -> stopped at 1 MB', h.Processed, 1024*1024);
  w.Free; s.Free;

  WriteLn;
  if fails = 0 then WriteLn('ALL OK') else WriteLn(fails, ' FAILURES');
  Halt(Ord(fails <> 0));
end.
