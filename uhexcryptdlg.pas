unit uhexcryptdlg;

{$mode objfpc}{$H+}

// Symmetric crypto dialog. Encrypts/decrypts the current selection of a THexView
// in place (undoable) using CNG via uhexcrypt. Key / IV entered as hex.

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, Clipbrd, uHexView, uhexcrypt;

type
  TCryptoForm = class(TForm)
  private
    FView: THexView;
    FAlg, FMode: TComboBox;
    FKey, FIV, FTag, FResult: TEdit;
    FPad: TCheckBox;
    FInfo, FStatus: TLabel;
    FLastResult: TBytes;
    procedure BuildUI;
    procedure AlgChange(Sender: TObject);
    procedure DoEncrypt(Sender: TObject);
    procedure DoDecrypt(Sender: TObject);
    procedure DoPutBack(Sender: TObject);
    procedure DoCopyResult(Sender: TObject);
    procedure Run(AEncrypt: Boolean);
    procedure DoPbkdf2(Sender: TObject);
    function IsGcm: Boolean;
    function CurAlg: TSymAlg;
    function CurMode: TSymMode;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure SetKeyHex(const AHex: string);
    procedure SetIVHex(const AHex: string);
    property View: THexView read FView write FView;
  end;

procedure ShowCrypto(AOwner: TComponent; AView: THexView);

implementation

function HexToBytes(const S: string): TBytes;
var clean: string; i, n: Integer;
  function HV(c: Char): Integer;
  begin
    case c of '0'..'9': HV := Ord(c)-Ord('0');
      'a'..'f': HV := Ord(c)-Ord('a')+10; 'A'..'F': HV := Ord(c)-Ord('A')+10;
    else HV := -1; end;
  end;
begin
  Result := nil;
  clean := '';
  for i := 1 to Length(S) do if HV(S[i]) >= 0 then clean := clean + S[i];
  n := Length(clean) div 2;
  SetLength(Result, n);
  for i := 0 to n-1 do
    Result[i] := HV(clean[i*2+1]) shl 4 or HV(clean[i*2+2]);
end;

constructor TCryptoForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('cry.title', 'Symmetric crypto (CNG)');
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  ClientWidth := 560;
  ClientHeight := 372;
  BuildUI;
  AlgChange(nil);
end;

procedure TCryptoForm.BuildUI;
  function Lab(ax, ay, aw: Integer; const c: string): TLabel;
  begin Result := TLabel.Create(Self); Result.Parent := Self;
    Result.SetBounds(ax, ay, aw, 18); Result.Caption := c; end;
begin
  Lab(12, 15, 70, L('cry.alg', 'Algorithm:'));
  FAlg := TComboBox.Create(Self); FAlg.Parent := Self;
  FAlg.SetBounds(88, 12, 120, 24); FAlg.Style := csDropDownList;
  FAlg.Items.CommaText := 'AES,3DES,DES,RC4'; FAlg.ItemIndex := 0;
  FAlg.OnChange := @AlgChange;

  Lab(230, 15, 50, L('cry.mode', 'Mode:'));
  FMode := TComboBox.Create(Self); FMode.Parent := Self;
  FMode.SetBounds(280, 12, 120, 24); FMode.Style := csDropDownList;
  FMode.Items.CommaText := 'ECB,CBC,CFB,GCM'; FMode.ItemIndex := 1;
  FMode.OnChange := @AlgChange;

  FPad := TCheckBox.Create(Self); FPad.Parent := Self;
  FPad.SetBounds(410, 14, 140, 20); FPad.Caption := L('cry.pkcs7', 'PKCS7 padding');
  FPad.OnClick := @AlgChange;

  Lab(12, 52, 70, L('cry.key', 'Key (hex):'));
  FKey := TEdit.Create(Self); FKey.Parent := Self;
  FKey.SetBounds(88, 49, 350, 24); FKey.Font.Name := 'Courier New'; FKey.Font.Size := 9;

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(446, 49, 102, 24);
    Caption := L('cry.pbkdf2', 'PBKDF2...'); OnClick := @DoPbkdf2; end;

  Lab(12, 88, 70, L('cry.iv', 'IV/Nonce:'));
  FIV := TEdit.Create(Self); FIV.Parent := Self;
  FIV.SetBounds(88, 85, 460, 24); FIV.Font.Name := 'Courier New'; FIV.Font.Size := 9;

  Lab(12, 124, 70, L('cry.tag', 'Tag (hex):'));
  FTag := TEdit.Create(Self); FTag.Parent := Self;
  FTag.SetBounds(88, 121, 460, 24); FTag.Font.Name := 'Courier New'; FTag.Font.Size := 9;

  FInfo := Lab(12, 156, 536, '');
  FInfo.Font.Color := $808000;

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(88, 182, 130, 30); Caption := L('cry.encrypt', 'Encrypt selection'); OnClick := @DoEncrypt; end;
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(230, 182, 130, 30); Caption := L('cry.decrypt', 'Decrypt selection'); OnClick := @DoDecrypt; end;

  Lab(12, 224, 90, L('cry.result', 'Result (hex):'));
  FResult := TEdit.Create(Self); FResult.Parent := Self;
  FResult.SetBounds(12, 242, 536, 24); FResult.ReadOnly := True;
  FResult.Font.Name := 'Courier New'; FResult.Font.Size := 9;

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(12, 276, 210, 30);
    Caption := L('cry.putback', '<<-- Върни обратно във файла'); OnClick := @DoPutBack; end;
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(232, 276, 120, 30); Caption := L('cry.copyresult', 'Copy result'); OnClick := @DoCopyResult; end;

  FStatus := Lab(12, 320, 536, '');
end;

function TCryptoForm.CurAlg: TSymAlg;
begin
  case FAlg.ItemIndex of 1: Result := sa3DES; 2: Result := saDES; 3: Result := saRC4; else Result := saAES; end;
end;

function TCryptoForm.IsGcm: Boolean;
begin
  Result := (FMode.ItemIndex = 3) and (CurAlg = saAES);
end;

function TCryptoForm.CurMode: TSymMode;
begin
  case FMode.ItemIndex of 0: Result := smECB; 2: Result := smCFB; else Result := smCBC; end;
end;

procedure TCryptoForm.AlgChange(Sender: TObject);
var a: TSymAlg; bs: Integer; keyInfo: string; gcm: Boolean;
begin
  a := CurAlg;
  bs := SymBlockSize(a);
  gcm := IsGcm;
  FMode.Enabled := (a <> saRC4);
  FTag.Enabled := gcm;
  FPad.Enabled := (a <> saRC4) and (not gcm);
  FIV.Enabled := gcm or SymNeedsIV(a, CurMode);
  if gcm then
    FInfo.Caption := L('cry.info.gcm',
      'AES-GCM: key 16/24/32, nonce 12 bytes (IV field). Encrypt fills Tag; decrypt verifies it.')
  else if a = saRC4 then
    FInfo.Caption := Format('%s - %s; no IV, any length', [SymAlgName(a),
      L('cry.info.rc4key', 'key 1..256 bytes (stream)')])
  else if FPad.Checked then
    FInfo.Caption := Format(L('cry.info.pad', '%s block %d - PKCS7 padding (length changes).'),
      [SymAlgName(a), bs])
  else
    FInfo.Caption := Format(L('cry.info.block', '%s block %d - selection must be a multiple of %d.'),
      [SymAlgName(a), bs, bs]);
end;

procedure TCryptoForm.DoEncrypt(Sender: TObject);
begin Run(True); end;

procedure TCryptoForm.DoDecrypt(Sender: TObject);
begin Run(False); end;

procedure TCryptoForm.Run(AEncrypt: Boolean);
var inp, outp, key, iv, gtag: TBytes; err, hex: string; i: Integer; ok: Boolean;
begin
  FStatus.Caption := '';
  if not Assigned(FView) then Exit;
  if FView.SelCount <= 0 then
  begin FStatus.Caption := L('cry.err.nosel', 'Маркирай диапазон първо.'); Exit; end;

  inp := FView.ReadSelection;
  key := HexToBytes(FKey.Text);
  iv  := HexToBytes(FIV.Text);

  if IsGcm then
  begin
    if AEncrypt then
    begin
      gtag := nil;
      ok := AesGcm(key, iv, inp, nil, AEncrypt, gtag, outp, err);
      if ok then
      begin
        hex := '';
        for i := 0 to High(gtag) do hex := hex + IntToHex(gtag[i], 2);
        FTag.Text := hex;    // show the produced tag
      end;
    end
    else
    begin
      gtag := HexToBytes(FTag.Text);
      ok := AesGcm(key, iv, inp, nil, AEncrypt, gtag, outp, err);
    end;
  end
  else if FPad.Checked and (CurAlg <> saRC4) then
    ok := SymCryptPKCS7(CurAlg, CurMode, key, iv, inp, AEncrypt, outp, err)
  else
    ok := SymCrypt(CurAlg, CurMode, key, iv, inp, AEncrypt, outp, err);

  if ok then
  begin
    FLastResult := outp;
    hex := '';
    for i := 0 to High(outp) do hex := hex + IntToHex(outp[i], 2);
    FResult.Text := hex;
    FStatus.Caption := Format(L('cry.ok', '%s OK - %d bytes. Review, then "Put back into file".'),
      [BoolToStr(AEncrypt, 'Encrypt', 'Decrypt'), Length(outp)]);
  end
  else
  begin
    FLastResult := nil;
    FResult.Text := '';
    FStatus.Caption := L('cry.error', 'Error: ') + err;
  end;
end;

procedure TCryptoForm.DoPbkdf2(Sender: TObject);
var pwd, saltHex, iterS, dkS: string; salt, dk: TBytes; iter, dklen, i: Integer; err, hex: string;
begin
  pwd := '';
  if not InputQuery(L('pbk.title', 'PBKDF2'), L('pbk.pwd', 'Password (text):'), pwd) then Exit;
  saltHex := '';
  if not InputQuery(L('pbk.title', 'PBKDF2'), L('pbk.salt', 'Salt (hex):'), saltHex) then Exit;
  iterS := '100000';
  if not InputQuery(L('pbk.title', 'PBKDF2'), L('pbk.iter', 'Iterations:'), iterS) then Exit;
  dkS := '32';
  if not InputQuery(L('pbk.title', 'PBKDF2'), L('pbk.dklen', 'Key length (bytes):'), dkS) then Exit;

  iter := StrToIntDef(iterS, 100000);
  dklen := StrToIntDef(dkS, 32);
  salt := HexToBytes(saltHex);

  if Pbkdf2(BytesOf(pwd), salt, iter, dklen, dk, err) then
  begin
    hex := '';
    for i := 0 to High(dk) do hex := hex + IntToHex(dk[i], 2);
    FKey.Text := hex;
    FStatus.Caption := Format(L('pbk.ok', 'Derived %d-byte key (HMAC-SHA256, %d iters).'), [dklen, iter]);
  end
  else
    FStatus.Caption := L('cry.error', 'Error: ') + err;
end;

procedure TCryptoForm.DoPutBack(Sender: TObject);
begin
  if Length(FLastResult) = 0 then
  begin FStatus.Caption := L('cry.err.noresult', 'Няма резултат за връщане.'); Exit; end;
  if not Assigned(FView) or not FView.IsEditable then
  begin FStatus.Caption := L('cry.err.readonly', 'Изгледът е само за четене (устройство).'); Exit; end;
  if FView.SelCount <> Length(FLastResult) then
  begin FStatus.Caption := Format('Селекцията (%d) не съвпада с резултата (%d).',
      [FView.SelCount, Length(FLastResult)]); Exit; end;
  FView.OverwriteSelection(FLastResult);
  FStatus.Caption := Format('Записани %d байта във файла (undo с Ctrl+Z).', [Length(FLastResult)]);
end;

procedure TCryptoForm.DoCopyResult(Sender: TObject);
begin
  Clipboard.AsText := FResult.Text;
end;

procedure TCryptoForm.SetKeyHex(const AHex: string);
begin
  FKey.Text := AHex;
end;

procedure TCryptoForm.SetIVHex(const AHex: string);
begin
  FIV.Text := AHex;
end;

procedure ShowCrypto(AOwner: TComponent; AView: THexView);
var f: TCryptoForm;
begin
  f := TCryptoForm.CreateNew(AOwner);
  f.FView := AView;
  f.Show;
end;

end.
