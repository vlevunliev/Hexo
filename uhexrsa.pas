unit uhexrsa;

{$mode objfpc}{$H+}

// RSA-style modular exponentiation dialog: result = base ^ exponent mod modulus,
// with arbitrary-size hex operands (paste with spaces/newlines is fine - any
// non-hex character is ignored). Built in code, uses ubigint.

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, Clipbrd, ubigint;

type
  TRsaForm = class(TForm)
  private
    FBase, FExp, FMod, FResult: TMemo;
    FLblTime: TLabel;
    procedure BuildUI;
    procedure DoCompute(Sender: TObject);
    procedure DoE65537(Sender: TObject);
    procedure DoCopy(Sender: TObject);
    procedure DoClear(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure SetBaseHex(const AHex: string);
    procedure SetModulusHex(const AHex: string);
    procedure SetExpHex(const AHex: string);
  end;

procedure ShowRsaModPow(AOwner: TComponent);

implementation

procedure ShowRsaModPow(AOwner: TComponent);
var f: TRsaForm;
begin
  f := TRsaForm.CreateNew(AOwner);
  f.Show;
end;

constructor TRsaForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('rsa.title', 'RSA modular exponentiation  (base ^ exp mod modulus)');
  Position := poScreenCenter;
  ClientWidth := 580;
  ClientHeight := 500;
  BuildUI;
end;

procedure TRsaForm.BuildUI;
  function Lab(ATop: Integer; const ACap: string): TLabel;
  begin
    Result := TLabel.Create(Self); Result.Parent := Self;
    Result.SetBounds(10, ATop, 300, 16); Result.Caption := ACap;
  end;
  function Mem(ATop, AH: Integer; ARO: Boolean): TMemo;
  begin
    Result := TMemo.Create(Self); Result.Parent := Self;
    Result.SetBounds(10, ATop, 560, AH);
    Result.ScrollBars := ssVertical; Result.WordWrap := True;
    Result.Font.Name := 'Courier New'; Result.Font.Size := 9;
    Result.ReadOnly := ARO;
  end;
begin
  Lab(8, L('rsa.base', 'Base (hex):'));
  FBase := Mem(26, 72, False);

  Lab(104, L('rsa.exp', 'Exponent (hex):'));
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(120, 100, 90, 22); Caption := L('rsa.e65537', 'e = 65537'); OnClick := @DoE65537; end;
  FExp := Mem(122, 48, False);

  Lab(176, L('rsa.mod', 'Modulus (hex):'));
  FMod := Mem(194, 72, False);

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(10, 274, 200, 28); Caption := L('rsa.compute', 'Compute  base ^ exp mod n'); OnClick := @DoCompute; end;
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(220, 274, 80, 28); Caption := L('rsa.clear', 'Clear'); OnClick := @DoClear; end;
  FLblTime := TLabel.Create(Self); FLblTime.Parent := Self;
  FLblTime.SetBounds(310, 280, 260, 18); FLblTime.Caption := '';

  Lab(312, L('rsa.result', 'Result (hex):'));
  FResult := Mem(330, 120, True);

  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(10, 460, 200, 28); Caption := L('rsa.copyresult', 'Copy result'); OnClick := @DoCopy; end;
end;

procedure TRsaForm.SetBaseHex(const AHex: string);
begin FBase.Text := AHex; end;

procedure TRsaForm.SetModulusHex(const AHex: string);
begin FMod.Text := AHex; end;

procedure TRsaForm.SetExpHex(const AHex: string);
begin FExp.Text := AHex; end;

procedure TRsaForm.DoE65537(Sender: TObject);
begin FExp.Text := '10001'; end;   // 65537

procedure TRsaForm.DoCompute(Sender: TObject);
var
  b, e, m, r: TLimbs;
  t0, t1: TDateTime;
begin
  m := BiFromHex(FMod.Text);
  if BiIsZero(m) then
  begin
    FResult.Text := L('rsa.err.zeromod', '(error: modulus is zero / empty)');
    Exit;
  end;
  b := BiFromHex(FBase.Text);
  e := BiFromHex(FExp.Text);
  FLblTime.Caption := L('rsa.computing', 'computing...');
  FResult.Text := '';
  Application.ProcessMessages;
  t0 := Now;
  r := BiModPow(b, e, m);
  t1 := Now;
  FResult.Text := BiToHex(r);
  FLblTime.Caption := Format('%.0f ms', [(t1 - t0) * 24 * 60 * 60 * 1000]);
end;

procedure TRsaForm.DoClear(Sender: TObject);
begin
  FBase.Clear; FExp.Clear; FMod.Clear; FResult.Clear; FLblTime.Caption := '';
end;

procedure TRsaForm.DoCopy(Sender: TObject);
begin
  Clipboard.AsText := Trim(FResult.Text);
end;

end.
