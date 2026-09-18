unit ulang;

{$mode objfpc}{$H+}

// Tiny runtime localization. All UI strings go through L('key', 'default').
// A translation file (UTF-8, key=value lines, ';' comments) can override any
// key at startup. LangSaveTemplate dumps every string seen so far so the file
// can be produced and translated. No dependencies.

interface

uses
  Classes, SysUtils;

function L(const AKey, ADefault: string): string;
procedure LangLoadFile(const AFileName: string);
procedure LangSaveTemplate(const AFileName: string);
function LangFileName: string;   // <exe dir>\hexview.lng

implementation

var
  Trans: TStringList = nil;   // loaded overrides  key=value
  Defs:  TStringList = nil;   // registered defaults key=default (insertion order)

procedure Ensure;
begin
  if Trans = nil then begin Trans := TStringList.Create; Trans.CaseSensitive := True; end;
  if Defs = nil then begin Defs := TStringList.Create; Defs.CaseSensitive := True; end;
end;

function L(const AKey, ADefault: string): string;
var i: Integer;
begin
  Ensure;
  if Defs.IndexOfName(AKey) < 0 then Defs.Add(AKey + '=' + ADefault);
  i := Trans.IndexOfName(AKey);
  if i >= 0 then Result := Trans.ValueFromIndex[i]
  else Result := ADefault;
end;

procedure LangLoadFile(const AFileName: string);
begin
  Ensure;
  Trans.Clear;
  if FileExists(AFileName) then
    try
      Trans.LoadFromFile(AFileName);
    except
      Trans.Clear;
    end;
end;

procedure LangSaveTemplate(const AFileName: string);
var sl: TStringList; i: Integer;
begin
  Ensure;
  sl := TStringList.Create;
  try
    sl.Add('; THexView language file  (UTF-8).  key=value, ; = comment.');
    sl.Add('; Edit the right-hand side; leave keys unchanged.');
    sl.Add('');
    for i := 0 to Defs.Count - 1 do sl.Add(Defs[i]);
    sl.SaveToFile(AFileName);
  finally
    sl.Free;
  end;
end;

function LangFileName: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'hexview.lng';
end;

finalization
  Trans.Free;
  Defs.Free;
end.
