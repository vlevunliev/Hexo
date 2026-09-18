unit uhexchk;

{$mode objfpc}{$H+}

// Checksum / hash results dialog. Computes CRC16/CRC32/CRC64 + MD5/SHA* (CNG)
// over a byte range in a single pass and shows them read-only. Also has an HMAC
// panel: pick the hash, enter a hex key, Compute.
//
// The pass is NOT started behind a frozen UI: the dialog opens first, shows the
// size of the range, and hashes with a progress bar, live speed/ETA and a
// working Cancel. Ranges up to AUTO_LIMIT start on their own; anything bigger
// (a whole physical drive, typically) waits for the user to press Compute, so
// "Extras -> Checksum" on \\.\PhysicalDrive0 with nothing selected can no
// longer lock the application up for hours.

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, Clipbrd,
  uhexhash;

procedure ShowChecksums(AOwner: TComponent; AReader: TBlockReader;
  AStart, ALen: Int64; const ARangeCaption: string);

implementation

uses Graphics;

const
  // ranges at or below this are hashed as soon as the dialog opens
  AUTO_LIMIT = Int64(64) * 1024 * 1024;

type
  TChkForm = class(TForm)
  private
    FHashes: THashSet;
    FEds: array[0..7] of TEdit;
    FReader: TBlockReader;
    FStart, FLen: Int64;
    FHmacAlg: TComboBox;
    FHmacKey: TEdit;
    FHmacOut: TEdit;
    FBtnGo: TButton;
    FBtnHmac: TButton;
    FProg: TProgressBar;
    FStatus: TLabel;
    FRunning: Boolean;
    FCancel: Boolean;
    FT0, FLastTick: QWord;
    procedure DoCopyAll(Sender: TObject);
    procedure DoHmac(Sender: TObject);
    procedure DoCompute(Sender: TObject);
    procedure Progress(APos, ATotal: Int64);
    procedure SetRunning(AOn: Boolean);
    procedure ClearRows;
    procedure FShow(Sender: TObject);
    procedure AsyncStart(Data: PtrInt);
    procedure FCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure Fill(const AHashes: THashSet);
    procedure SetSource(AReader: TBlockReader; AStart, ALen: Int64;
      const ARangeCaption: string);
  end;

function HexToBytes(const S: string): TBytes;
var clean: string; i, n: Integer;
  function HV(c: Char): Integer;
  begin
    case c of '0'..'9': HV := Ord(c)-Ord('0');
      'a'..'f': HV := Ord(c)-Ord('a')+10; 'A'..'F': HV := Ord(c)-Ord('A')+10;
    else HV := -1; end;
  end;
begin
  Result := nil; clean := '';
  for i := 1 to Length(S) do if HV(S[i]) >= 0 then clean := clean + S[i];
  n := Length(clean) div 2; SetLength(Result, n);
  for i := 0 to n-1 do Result[i] := HV(clean[i*2+1]) shl 4 or HV(clean[i*2+2]);
end;

function FmtBytes(V: Int64): string;
begin
  if V >= Int64(1024)*1024*1024*1024 then
    Result := Format('%.2f TB', [V / (Int64(1024)*1024*1024*1024)])
  else if V >= 1024*1024*1024 then
    Result := Format('%.2f GB', [V / (1024*1024*1024)])
  else if V >= 1024*1024 then
    Result := Format('%.1f MB', [V / (1024*1024)])
  else if V >= 1024 then
    Result := Format('%.1f KB', [V / 1024])
  else
    Result := Format('%d B', [V]);
end;

function FmtDur(Secs: Int64): string;
begin
  if Secs < 0 then Secs := 0;
  if Secs >= 3600 then
    Result := Format('%dh %02dm', [Secs div 3600, (Secs mod 3600) div 60])
  else if Secs >= 60 then
    Result := Format('%dm %02ds', [Secs div 60, Secs mod 60])
  else
    Result := Format('%ds', [Secs]);
end;

const
  RowName: array[0..7] of string =
    ('CRC16', 'CRC32', 'CRC64', 'MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512');

constructor TChkForm.CreateNew(AOwner: TComponent; Num: Integer);
var i, y: Integer; lbl: TLabel;
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('chk.title', 'Checksums / hashes');
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  ClientWidth := 720;
  ClientHeight := 432;

  lbl := TLabel.Create(Self); lbl.Parent := Self; lbl.Name := 'lblRange';
  lbl.SetBounds(12, 10, 700, 16);

  y := 34;
  for i := 0 to 7 do
  begin
    lbl := TLabel.Create(Self); lbl.Parent := Self;
    lbl.SetBounds(12, y + 3, 60, 16); lbl.Caption := RowName[i];
    FEds[i] := TEdit.Create(Self); FEds[i].Parent := Self;
    FEds[i].SetBounds(74, y, 634, 24); FEds[i].ReadOnly := True;
    FEds[i].Font.Name := 'Courier New'; FEds[i].Font.Size := 9;
    Inc(y, 28);
  end;

  // ---- compute / cancel + progress ----
  FBtnGo := TButton.Create(Self); FBtnGo.Parent := Self;
  FBtnGo.SetBounds(74, y + 6, 150, 28);
  FBtnGo.Caption := L('chk.compute', 'Compute');
  FBtnGo.OnClick := @DoCompute;
  FBtnGo.Default := True;

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(236, y + 6, 140, 28);
    Caption := L('chk.copyall', 'Copy all'); OnClick := @DoCopyAll; end;

  FStatus := TLabel.Create(Self); FStatus.Parent := Self;
  FStatus.SetBounds(388, y + 12, 320, 18);

  FProg := TProgressBar.Create(Self); FProg.Parent := Self;
  FProg.SetBounds(74, y + 40, 634, 14);
  FProg.Min := 0; FProg.Max := 1000; FProg.Position := 0;

  // ---- HMAC panel ----
  Inc(y, 68);
  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(12, y, 700, 16); lbl.Caption := L('chk.hmac', 'HMAC (keyed):');
  Inc(y, 22);

  FHmacAlg := TComboBox.Create(Self); FHmacAlg.Parent := Self;
  FHmacAlg.SetBounds(12, y, 120, 26); FHmacAlg.Style := csDropDownList;
  FHmacAlg.Items.CommaText := 'MD5,SHA1,SHA256,SHA384,SHA512';
  FHmacAlg.ItemIndex := 2;

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(142, y + 4, 60, 16); lbl.Caption := L('chk.hmac.key', 'Key (hex):');
  FHmacKey := TEdit.Create(Self); FHmacKey.Parent := Self;
  FHmacKey.SetBounds(206, y, 380, 24);
  FHmacKey.Font.Name := 'Courier New'; FHmacKey.Font.Size := 9;

  FBtnHmac := TButton.Create(Self); FBtnHmac.Parent := Self;
  FBtnHmac.SetBounds(596, y - 1, 112, 26);
  FBtnHmac.Caption := L('chk.hmac.compute', 'Compute');
  FBtnHmac.OnClick := @DoHmac;
  Inc(y, 30);

  FHmacOut := TEdit.Create(Self); FHmacOut.Parent := Self;
  FHmacOut.SetBounds(12, y, 696, 24); FHmacOut.ReadOnly := True;
  FHmacOut.Font.Name := 'Courier New'; FHmacOut.Font.Size := 9;

  OnShow := @FShow;
  OnCloseQuery := @FCloseQuery;
end;

procedure TChkForm.SetSource(AReader: TBlockReader; AStart, ALen: Int64;
  const ARangeCaption: string);
begin
  FReader := AReader; FStart := AStart; FLen := ALen;
  (FindComponent('lblRange') as TLabel).Caption := ARangeCaption;
  if FLen > AUTO_LIMIT then
    FStatus.Caption := Format(L('chk.warnbig', '%s - press Compute'),
      [FmtBytes(FLen)])
  else
    FStatus.Caption := '';
end;

procedure TChkForm.ClearRows;
var i: Integer;
begin
  for i := 0 to 7 do FEds[i].Text := '';
end;

procedure TChkForm.SetRunning(AOn: Boolean);
begin
  FRunning := AOn;
  if AOn then FBtnGo.Caption := L('chk.cancel', 'Cancel')
  else FBtnGo.Caption := L('chk.compute', 'Compute');
  FBtnHmac.Enabled := not AOn;
  FHmacAlg.Enabled := not AOn;
  FHmacKey.Enabled := not AOn;
  // keep the user out of the view while a pass streams from it on this thread
  if (Owner <> nil) and (Owner is TCustomForm) then
    TCustomForm(Owner).Enabled := not AOn;
  if AOn then Screen.Cursor := crHourGlass else Screen.Cursor := crDefault;
end;

procedure TChkForm.Progress(APos, ATotal: Int64);
var
  now, el: QWord;
  sp: Double;
  s: string;
begin
  now := GetTickCount64;
  if (APos < ATotal) and (now - FLastTick < 200) then
  begin
    Application.ProcessMessages;   // stay responsive between label updates
    Exit;
  end;
  FLastTick := now;

  if ATotal > 0 then FProg.Position := Round(APos / ATotal * 1000);
  el := now - FT0;
  s := FmtBytes(APos) + ' / ' + FmtBytes(ATotal);
  if el > 500 then
  begin
    sp := APos / (el / 1000);                       // bytes per second
    s := s + Format('  -  %s/s', [FmtBytes(Round(sp))]);
    if sp > 0 then
      s := s + '  -  ' + Format(L('chk.eta', 'left %s'),
        [FmtDur(Round((ATotal - APos) / sp))]);
  end;
  FStatus.Caption := s;
  Application.ProcessMessages;
end;

procedure TChkForm.DoCompute(Sender: TObject);
var h: THashSet;
begin
  if FRunning then
  begin
    FCancel := True;                       // button doubles as Cancel
    FStatus.Caption := L('chk.cancelling', 'Cancelling...');
    Exit;
  end;
  if not Assigned(FReader) then Exit;

  ClearRows;
  FCancel := False;
  FT0 := GetTickCount64; FLastTick := 0;
  SetRunning(True);
  try
    h := HashAll(FReader, FStart, FLen, @Progress, @FCancel);
  finally
    SetRunning(False);
    FProg.Position := 0;
  end;
  Fill(h);
end;

procedure TChkForm.Fill(const AHashes: THashSet);
begin
  FHashes := AHashes;
  if AHashes.Cancelled then
  begin
    // a digest of a partial pass is not a digest of the range - don't show one
    ClearRows;
    FStatus.Caption := Format(L('chk.cancelled', 'Cancelled - covers %s'),
      [FmtBytes(AHashes.Processed)]);
    Exit;
  end;
  FEds[0].Text := AHashes.CRC16;
  FEds[1].Text := AHashes.CRC32;
  FEds[2].Text := AHashes.CRC64;
  FEds[3].Text := AHashes.MD5;
  FEds[4].Text := AHashes.SHA1;
  FEds[5].Text := AHashes.SHA256;
  FEds[6].Text := AHashes.SHA384;
  FEds[7].Text := AHashes.SHA512;

  if not AHashes.Complete then
    FStatus.Caption := Format(L('chk.partial',
      'Read stopped early - covers %s of %s'),
      [FmtBytes(AHashes.Processed), FmtBytes(FLen)])
  else
    FStatus.Caption := Format(L('chk.done', 'Done - %s in %s'),
      [FmtBytes(AHashes.Processed), FmtDur((GetTickCount64 - FT0) div 1000)]);
end;

procedure TChkForm.FShow(Sender: TObject);
begin
  OnShow := nil;                       // one shot
  // start after the form is actually on screen, never from inside OnShow
  if (FLen > 0) and (FLen <= AUTO_LIMIT) then
    Application.QueueAsyncCall(@AsyncStart, 0);
end;

procedure TChkForm.AsyncStart(Data: PtrInt);
begin
  if (not FRunning) and Showing then DoCompute(nil);
end;

procedure TChkForm.FCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // never tear the form down under a running pass - the callback below us
  // still holds FReader; cancel first, the pass unwinds and then it closes
  if FRunning then
  begin
    FCancel := True;
    FStatus.Caption := L('chk.cancelling', 'Cancelling...');
    CanClose := False;
  end
  else
    CanClose := True;
end;

procedure TChkForm.DoCopyAll(Sender: TObject);
begin
  Clipboard.AsText :=
    'CRC16:  ' + FHashes.CRC16  + LineEnding +
    'CRC32:  ' + FHashes.CRC32  + LineEnding +
    'CRC64:  ' + FHashes.CRC64  + LineEnding +
    'MD5:    ' + FHashes.MD5    + LineEnding +
    'SHA1:   ' + FHashes.SHA1   + LineEnding +
    'SHA256: ' + FHashes.SHA256 + LineEnding +
    'SHA384: ' + FHashes.SHA384 + LineEnding +
    'SHA512: ' + FHashes.SHA512;
end;

procedure TChkForm.DoHmac(Sender: TObject);
var kind: THmacKind; key: TBytes; res: string;
begin
  if FRunning then Exit;
  if not Assigned(FReader) then Exit;
  case FHmacAlg.ItemIndex of
    0: kind := hmMD5;   1: kind := hmSHA1;   3: kind := hmSHA384;
    4: kind := hmSHA512;
  else kind := hmSHA256;
  end;
  key := HexToBytes(FHmacKey.Text);

  FHmacOut.Text := '';
  FCancel := False;
  FT0 := GetTickCount64; FLastTick := 0;
  SetRunning(True);
  try
    res := HmacRange(kind, key, FReader, FStart, FLen, @Progress, @FCancel);
  finally
    SetRunning(False);
    FProg.Position := 0;
  end;
  if FCancel then
    FStatus.Caption := L('chk.cancelled.short', 'Cancelled')
  else
  begin
    FHmacOut.Text := HmacKindName(kind) + ' = ' + res;
    FStatus.Caption := Format(L('chk.done', 'Done - %s in %s'),
      [FmtBytes(FLen), FmtDur((GetTickCount64 - FT0) div 1000)]);
  end;
end;

procedure ShowChecksums(AOwner: TComponent; AReader: TBlockReader;
  AStart, ALen: Int64; const ARangeCaption: string);
var f: TChkForm;
begin
  f := TChkForm.CreateNew(AOwner);
  if AOwner is TCustomForm then
  begin
    f.ShowInTaskBar := stNever;
    f.PopupMode := pmExplicit;
    f.PopupParent := TCustomForm(AOwner);
  end;
  f.SetSource(AReader, AStart, ALen, ARangeCaption);
  f.Show;                       // dialog first, hashing after
end;

end.
