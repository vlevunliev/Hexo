unit uhexcalc;

{$mode objfpc}{$H+}

// Programmer / hex calculator for the THexView demo. Built entirely in code
// (no .lfm). Int64 arithmetic with selectable bit width (8/16/32/64), live
// HEX/DEC/OCT/BIN display, bitwise ops, and an optional "send value" callback
// (used by the host to Goto an offset).

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, Buttons, ExtCtrls, LCLType;

type
  TCalcSendEvent = procedure(AValue: Int64) of object;

  { pure helpers (unit-testable) }
  function CalcFormat(AValue: Int64; ABase, AWidthBits: Integer): string;
  function CalcMask(AValue: Int64; AWidthBits: Integer): Int64;

type
  TCalcOp = (opNone, opAdd, opSub, opMul, opDiv, opMod, opAnd, opOr, opXor,
    opShl, opShr);

  TCalcForm = class(TForm)
  private
    FBase: Integer;         // 2, 8, 10, 16
    FWidth: Integer;        // 8, 16, 32, 64
    FValue: Int64;          // current entry
    FAcc: Int64;            // accumulator
    FOp: TCalcOp;
    FEntering: Boolean;
    FOnSend: TCalcSendEvent;

    FEdHex, FEdDec, FEdOct, FEdBin: TEdit;
    FLblBase: TLabel;
    FDigitBtns: array[0..15] of TSpeedButton;

    procedure BuildUI;
    procedure Refresh;
    procedure UpdateDigitButtons;
    procedure DoDigit(Sender: TObject);
    procedure DoOp(Sender: TObject);
    procedure DoEquals(Sender: TObject);
    procedure DoNot(Sender: TObject);
    procedure DoClear(Sender: TObject);
    procedure DoBack(Sender: TObject);
    procedure DoSetBase(Sender: TObject);
    procedure DoSetWidth(Sender: TObject);
    procedure DoCopy(Sender: TObject);
    procedure DoSend(Sender: TObject);
    function Compute(A, B: Int64; AOp: TCalcOp): Int64;
    function MakeBtn(ACol, ARow: Integer; const ACap: string;
      AHandler: TNotifyEvent): TSpeedButton;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    property Value: Int64 read FValue;
    property OnSend: TCalcSendEvent read FOnSend write FOnSend;
  end;

procedure ShowCalculator(AOwner: TComponent; AOnSend: TCalcSendEvent);

implementation

{ ---- pure helpers ---------------------------------------------------------- }

function CalcMask(AValue: Int64; AWidthBits: Integer): Int64;
begin
  if AWidthBits >= 64 then Exit(AValue);
  Result := AValue and ((Int64(1) shl AWidthBits) - 1);
end;

function CalcFormat(AValue: Int64; ABase, AWidthBits: Integer): string;
var u: QWord; digits: string; d: Integer;
begin
  AValue := CalcMask(AValue, AWidthBits);
  u := QWord(AValue);
  if AWidthBits < 64 then u := u and ((QWord(1) shl AWidthBits) - 1);
  case ABase of
    10: Exit(IntToStr(Int64(u)));   // decimal: show as unsigned magnitude within width
    16: digits := '0123456789ABCDEF';
    8:  digits := '01234567';
    2:  digits := '01';
  else digits := '0123456789';
  end;
  if u = 0 then Exit('0');
  Result := '';
  while u > 0 do
  begin
    d := u mod QWord(ABase);
    Result := digits[d + 1] + Result;
    u := u div QWord(ABase);
  end;
end;

{ ---- form ------------------------------------------------------------------ }

procedure ShowCalculator(AOwner: TComponent; AOnSend: TCalcSendEvent);
var f: TCalcForm;
begin
  f := TCalcForm.CreateNew(AOwner);
  f.OnSend := AOnSend;
  f.Show;
end;

constructor TCalcForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  FBase := 16;
  FWidth := 64;
  FValue := 0;
  FAcc := 0;
  FOp := opNone;
  FEntering := False;
  Caption := L('calc.title', 'Hex calculator');
  BorderStyle := bsSingle;
  Position := poScreenCenter;
  ClientWidth := 396;
  ClientHeight := 452;
  BuildUI;
  Refresh;
end;

function TCalcForm.MakeBtn(ACol, ARow: Integer; const ACap: string;
  AHandler: TNotifyEvent): TSpeedButton;
const X0 = 12; Y0 = 168; W = 56; H = 40; GX = 6; GY = 6;
begin
  Result := TSpeedButton.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(X0 + ACol * (W + GX), Y0 + ARow * (H + GY), W, H);
  Result.Caption := ACap;
  Result.OnClick := AHandler;
end;

procedure TCalcForm.BuildUI;
  function MkDisp(ATop: Integer; const ACap: string; out AEd: TEdit): TLabel;
  begin
    Result := TLabel.Create(Self); Result.Parent := Self;
    Result.SetBounds(10, ATop + 3, 34, 20); Result.Caption := ACap;
    AEd := TEdit.Create(Self); AEd.Parent := Self;
    AEd.SetBounds(48, ATop, 336, 24); AEd.ReadOnly := True;
    AEd.Font.Name := 'Courier New'; AEd.Font.Size := 10;
  end;
var
  cb: TComboBox; i: Integer; d: Integer;
begin
  MkDisp(10,  L('calc.hex', 'HEX'), FEdHex);
  MkDisp(38,  L('calc.dec', 'DEC'), FEdDec);
  MkDisp(66,  L('calc.oct', 'OCT'), FEdOct);
  MkDisp(94,  L('calc.bin', 'BIN'), FEdBin);

  // base selector
  FLblBase := TLabel.Create(Self); FLblBase.Parent := Self;
  FLblBase.SetBounds(10, 128, 40, 20); FLblBase.Caption := L('calc.baselbl', 'Base:');
  cb := TComboBox.Create(Self); cb.Parent := Self;
  cb.SetBounds(48, 125, 90, 24); cb.Style := csDropDownList;
  cb.Items.Add(L('calc.hex', 'HEX')); cb.Items.Add(L('calc.dec', 'DEC')); cb.Items.Add(L('calc.oct', 'OCT')); cb.Items.Add(L('calc.bin', 'BIN'));
  cb.ItemIndex := 0; cb.OnChange := @DoSetBase; cb.Tag := 0;

  // width selector
  cb := TComboBox.Create(Self); cb.Parent := Self;
  cb.SetBounds(150, 125, 110, 24); cb.Style := csDropDownList;
  cb.Items.Add(L('calc.w.byte', 'BYTE  8'));  cb.Items.Add(L('calc.w.word', 'WORD 16'));
  cb.Items.Add(L('calc.w.dword', 'DWORD 32')); cb.Items.Add(L('calc.w.qword', 'QWORD 64'));
  cb.ItemIndex := 3; cb.OnChange := @DoSetWidth; cb.Tag := 1;

  // digit buttons A..F on the top keypad row, 0-9 laid out below
  // Layout grid (col,row):
  // row0: A B C D E F
  d := 10;
  for i := 0 to 5 do
  begin
    FDigitBtns[d] := MakeBtn(i, 0, Chr(Ord('A') + i), @DoDigit);
    FDigitBtns[d].Tag := d; Inc(d);
  end;
  // row1: 7 8 9  /  And Or
  FDigitBtns[7] := MakeBtn(0,1,'7',@DoDigit); FDigitBtns[7].Tag := 7;
  FDigitBtns[8] := MakeBtn(1,1,'8',@DoDigit); FDigitBtns[8].Tag := 8;
  FDigitBtns[9] := MakeBtn(2,1,'9',@DoDigit); FDigitBtns[9].Tag := 9;
  with MakeBtn(3,1,'/',@DoOp)  do Tag := Ord(opDiv);
  with MakeBtn(4,1,'AND',@DoOp) do Tag := Ord(opAnd);
  with MakeBtn(5,1,'OR',@DoOp)  do Tag := Ord(opOr);
  // row2: 4 5 6  *  Xor Not
  FDigitBtns[4] := MakeBtn(0,2,'4',@DoDigit); FDigitBtns[4].Tag := 4;
  FDigitBtns[5] := MakeBtn(1,2,'5',@DoDigit); FDigitBtns[5].Tag := 5;
  FDigitBtns[6] := MakeBtn(2,2,'6',@DoDigit); FDigitBtns[6].Tag := 6;
  with MakeBtn(3,2,'*',@DoOp)  do Tag := Ord(opMul);
  with MakeBtn(4,2,'XOR',@DoOp) do Tag := Ord(opXor);
  MakeBtn(5,2,'NOT',@DoNot);
  // row3: 1 2 3  -  Lsh Rsh
  FDigitBtns[1] := MakeBtn(0,3,'1',@DoDigit); FDigitBtns[1].Tag := 1;
  FDigitBtns[2] := MakeBtn(1,3,'2',@DoDigit); FDigitBtns[2].Tag := 2;
  FDigitBtns[3] := MakeBtn(2,3,'3',@DoDigit); FDigitBtns[3].Tag := 3;
  with MakeBtn(3,3,'-',@DoOp)  do Tag := Ord(opSub);
  with MakeBtn(4,3,'<<',@DoOp) do Tag := Ord(opShl);
  with MakeBtn(5,3,'>>',@DoOp) do Tag := Ord(opShr);
  // row4: 0 C  Bksp  +  Mod  =
  FDigitBtns[0] := MakeBtn(0,4,'0',@DoDigit); FDigitBtns[0].Tag := 0;
  MakeBtn(1,4,'C',@DoClear);
  MakeBtn(2,4,'<-',@DoBack);
  with MakeBtn(3,4,'+',@DoOp)   do Tag := Ord(opAdd);
  with MakeBtn(4,4,'MOD',@DoOp) do Tag := Ord(opMod);
  MakeBtn(5,4,'=',@DoEquals);

  // bottom: Copy + Goto
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(12, 404, 180, 30); Caption := L('calc.copyhex', 'Copy HEX'); OnClick := @DoCopy; end;
  with TButton.Create(Self) do
  begin Parent := Self; SetBounds(204, 404, 180, 30); Caption := L('calc.sendgoto', 'Send -> Goto'); OnClick := @DoSend; end;

  UpdateDigitButtons;
end;

procedure TCalcForm.UpdateDigitButtons;
var i, maxDigit: Integer;
begin
  case FBase of
    2:  maxDigit := 1;
    8:  maxDigit := 7;
    10: maxDigit := 9;
  else  maxDigit := 15;
  end;
  for i := 0 to 15 do
    if Assigned(FDigitBtns[i]) then FDigitBtns[i].Enabled := (i <= maxDigit);
end;

procedure TCalcForm.Refresh;
begin
  FEdHex.Text := CalcFormat(FValue, 16, FWidth);
  FEdDec.Text := CalcFormat(FValue, 10, FWidth);
  FEdOct.Text := CalcFormat(FValue, 8,  FWidth);
  FEdBin.Text := CalcFormat(FValue, 2,  FWidth);
end;

procedure TCalcForm.DoDigit(Sender: TObject);
var d: Integer;
begin
  d := TComponent(Sender).Tag;
  if not FEntering then begin FValue := 0; FEntering := True; end;
  FValue := CalcMask(FValue * FBase + d, FWidth);
  Refresh;
end;

function TCalcForm.Compute(A, B: Int64; AOp: TCalcOp): Int64;
begin
  case AOp of
    opAdd: Result := A + B;
    opSub: Result := A - B;
    opMul: Result := A * B;
    opDiv: if B <> 0 then Result := A div B else Result := 0;
    opMod: if B <> 0 then Result := A mod B else Result := 0;
    opAnd: Result := A and B;
    opOr:  Result := A or B;
    opXor: Result := A xor B;
    opShl: Result := A shl (B and 63);
    opShr: Result := A shr (B and 63);
  else Result := B;
  end;
  Result := CalcMask(Result, FWidth);
end;

procedure TCalcForm.DoOp(Sender: TObject);
begin
  if (FOp <> opNone) and FEntering then
    FAcc := Compute(FAcc, FValue, FOp)
  else
    FAcc := FValue;
  FValue := FAcc;
  FOp := TCalcOp(TComponent(Sender).Tag);
  FEntering := False;
  Refresh;
end;

procedure TCalcForm.DoEquals(Sender: TObject);
begin
  if FOp <> opNone then
  begin
    FValue := Compute(FAcc, FValue, FOp);
    FOp := opNone;
    FAcc := FValue;
    FEntering := False;
    Refresh;
  end;
end;

procedure TCalcForm.DoNot(Sender: TObject);
begin
  FValue := CalcMask(not FValue, FWidth);
  FEntering := False;
  Refresh;
end;

procedure TCalcForm.DoClear(Sender: TObject);
begin
  FValue := 0; FAcc := 0; FOp := opNone; FEntering := False;
  Refresh;
end;

procedure TCalcForm.DoBack(Sender: TObject);
begin
  FValue := CalcMask(FValue div FBase, FWidth);
  Refresh;
end;

procedure TCalcForm.DoSetBase(Sender: TObject);
begin
  case TComboBox(Sender).ItemIndex of
    0: FBase := 16;
    1: FBase := 10;
    2: FBase := 8;
    3: FBase := 2;
  end;
  FEntering := False;
  UpdateDigitButtons;
  Refresh;
end;

procedure TCalcForm.DoSetWidth(Sender: TObject);
begin
  case TComboBox(Sender).ItemIndex of
    0: FWidth := 8;
    1: FWidth := 16;
    2: FWidth := 32;
    3: FWidth := 64;
  end;
  FValue := CalcMask(FValue, FWidth);
  FAcc := CalcMask(FAcc, FWidth);
  Refresh;
end;

procedure TCalcForm.DoCopy(Sender: TObject);
begin
  FEdHex.SelectAll;
  FEdHex.CopyToClipboard;
end;

procedure TCalcForm.DoSend(Sender: TObject);
begin
  if Assigned(FOnSend) then FOnSend(CalcMask(FValue, FWidth));
end;

end.
