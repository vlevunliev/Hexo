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

// A .lng line cannot hold a real newline, so multi-line prompts travel as \n
// (and \t, \\). Escapes are resolved once, when the file is loaded.
function Unescape(const S: string): string;
var i: Integer;
begin
  Result := '';
  i := 1;
  while i <= Length(S) do
  begin
    if (S[i] = '\') and (i < Length(S)) then
      case S[i + 1] of
        'n': begin Result := Result + LineEnding; Inc(i, 2); Continue; end;
        't': begin Result := Result + #9;         Inc(i, 2); Continue; end;
        '\': begin Result := Result + '\';        Inc(i, 2); Continue; end;
      end;
    Result := Result + S[i];
    Inc(i);
  end;
end;

function Escape(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #13#10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
end;

procedure LangLoadFile(const AFileName: string);
var i: Integer; k: string;
begin
  Ensure;
  Trans.Clear;
  if FileExists(AFileName) then
    try
      Trans.LoadFromFile(AFileName);
      for i := 0 to Trans.Count - 1 do
      begin
        k := Trans.Names[i];
        if k <> '' then Trans[i] := k + '=' + Unescape(Trans.ValueFromIndex[i]);
      end;
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
    sl.Add('; \n = new line, \t = tab, \\ = backslash.');
    sl.Add('');
    for i := 0 to Defs.Count - 1 do
      sl.Add(Defs.Names[i] + '=' + Escape(Defs.ValueFromIndex[i]));
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
