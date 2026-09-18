program t_chkui;
{$mode objfpc}{$H+}
// harness: renders the reworked checksum dialog headless so the three states
// can be eyeballed - auto-computed small range, big range waiting for Compute,
// and a pass in flight (progress / throughput / ETA / Cancel).
//   t_chkui 1 -> 8 MB   (starts on its own)
//   t_chkui 2 -> 8 GB   (waits for Compute, like a whole physical drive)
uses Interfaces, Classes, SysUtils, Forms, uhexhash, uhexchk;

type
  TSrc = class
  public
    function Read(APos: Int64; var ABuf; ALen: Integer): Integer;
  end;

function TSrc.Read(APos: Int64; var ABuf; ALen: Integer): Integer;
begin
  FillChar(ABuf, ALen, Byte(APos and $FF));   // synthetic device-like source
  Result := ALen;
end;

var
  src: TSrc;
  len: Int64;
begin
  Application.Initialize;
  src := TSrc.Create;
  if ParamStr(1) = '2' then len := Int64(8)*1024*1024*1024
  else len := 8*1024*1024;
  ShowChecksums(nil, @src.Read, 0, len,
    Format('Whole file: %d bytes', [len]));
  Application.Run;
end.
