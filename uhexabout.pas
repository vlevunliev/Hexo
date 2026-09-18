unit uhexabout;

{$mode objfpc}{$H+}

// "Help -> About" dialog. Built entirely in code like the rest of the UI.
// Shows the app name/version, the build stamp of the binary that is actually
// running (FPC version, target CPU/OS, compile date), the live FindCrypt2
// database size, and the credits. "Copy info" puts the technical block on the
// clipboard in one go - that is the text to paste into a bug report.

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics,
  Clipbrd;

const
  HEXO_NAME    = 'HEXO';
  HEXO_VERSION = '1.0';
  HEXO_TAG     = 'VL';

// build stamp of this binary - filled by the compiler, not by hand
const
  BUILD_FPC  = {$I %FPCVERSION%};
  BUILD_OS   = {$I %FPCTARGETOS%};
  BUILD_CPU  = {$I %FPCTARGETCPU%};
  BUILD_DATE = {$I %DATE%};
  BUILD_TIME = {$I %TIME%};

// 'HEXO 1.0 (VL)' - also handy for a window caption or a log header
function HexoVersionString: string;

procedure ShowAbout(AOwner: TComponent);

implementation

uses
  lclversion, ufcdb;

type
  TAboutForm = class(TForm)
  private
    FInfo: TMemo;
    procedure DoCopy(Sender: TObject);
    procedure BtnClose(Sender: TObject);
    function BuildInfoText: string;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

function HexoVersionString: string;
begin
  Result := HEXO_NAME + ' ' + HEXO_VERSION;
  if HEXO_TAG <> '' then Result := Result + ' (' + HEXO_TAG + ')';
end;

// distinct algorithm names in the FindCrypt2 database (counted here rather than
// through ufindcrypt, so the About box does not drag in the scanner)
function AlgoCount: Integer;
var l: TStringList; i: Integer;
begin
  l := TStringList.Create;
  try
    l.Sorted := True; l.Duplicates := dupIgnore;
    for i := 0 to FCSigCount - 1 do l.Add(FCSig(i).Algo);
    Result := l.Count;
  finally
    l.Free;
  end;
end;

function TAboutForm.BuildInfoText: string;
const
  NL = LineEnding;
begin
  Result :=
    HexoVersionString + NL +
    Format(L('about.built', 'Built %s %s with Free Pascal %s'),
           [BUILD_DATE, BUILD_TIME, BUILD_FPC]) + NL +
    Format(L('about.target', 'Target: %s-%s   LCL %s'),
           [BUILD_CPU, BUILD_OS, lcl_version]) + NL +
    NL +
    L('about.line.engine',
      'Int64 virtual rendering; non-destructive piece-table editing') + NL +
    {$IFDEF WINDOWS}
    L('about.line.crypto',
      'Crypto: Windows CNG (bcrypt.dll) - no external DLLs') + NL +
    {$ELSE}
    L('about.line.nocrypto',
      'Crypto: Windows CNG only - unavailable on this platform') + NL +
    {$ENDIF}
    Format(L('about.line.fc', 'FindCrypt2 database: %d signatures, %d algorithms'),
           [FCSigCount, AlgoCount]) + NL +
    NL +
    L('about.credits.fc',
      'FindCrypt2 signature data: Ilfak Guilfanov (public domain).') + NL +
    L('about.credits.rest', 'Everything else: original code.');
end;

constructor TAboutForm.CreateNew(AOwner: TComponent; Num: Integer);
var
  img: TImage;
  lbl: TLabel;
  bv: TBevel;
  x, y: Integer;
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('about.title', 'About');
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  ClientWidth := 520;
  ClientHeight := 340;

  x := 16;
  img := TImage.Create(Self); img.Parent := Self;
  img.SetBounds(16, 16, 48, 48);
  img.Stretch := True; img.Center := True;
  try
    if (Application.Icon <> nil) and (not Application.Icon.Empty) then
    begin
      img.Picture.Icon.Assign(Application.Icon);
      x := 80;                       // text starts to the right of the icon
    end
    else
      img.Visible := False;
  except
    img.Visible := False;            // no icon resource - not worth a dialog
  end;

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(x, 14, 420, 26);
  lbl.Caption := HEXO_NAME;
  lbl.Font.Size := 16; lbl.Font.Style := [fsBold];

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(x, 42, 420, 18);
  lbl.Caption := L('about.sub', 'Int64 hex viewer / editor for forensics');

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(x, 62, 420, 18);
  lbl.Caption := Format(L('about.version', 'Version %s (%s)'),
    [HEXO_VERSION, HEXO_TAG]);

  bv := TBevel.Create(Self); bv.Parent := Self;
  bv.SetBounds(16, 92, 488, 2); bv.Shape := bsTopLine;

  FInfo := TMemo.Create(Self); FInfo.Parent := Self;
  FInfo.SetBounds(16, 104, 488, 168);
  FInfo.ReadOnly := True;
  FInfo.ScrollBars := ssAutoVertical;
  FInfo.WordWrap := False;
  FInfo.Font.Name := 'Courier New'; FInfo.Font.Size := 9;
  FInfo.Lines.Text := BuildInfoText;

  y := 286;
  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(16, y, 140, 30);
    Caption := L('about.copy', 'Copy info'); OnClick := @DoCopy;
  end;

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(384, y, 120, 30);
    Caption := L('about.close', 'Close'); OnClick := @BtnClose;
    Default := True; Cancel := True;
  end;
end;

procedure TAboutForm.DoCopy(Sender: TObject);
begin
  Clipboard.AsText := BuildInfoText;
end;

procedure TAboutForm.BtnClose(Sender: TObject);
begin
  Close;
end;

procedure ShowAbout(AOwner: TComponent);
var f: TAboutForm;
begin
  f := TAboutForm.CreateNew(AOwner);
  try
    if AOwner is TCustomForm then
    begin
      f.ShowInTaskBar := stNever;
      f.PopupMode := pmExplicit;
      f.PopupParent := TCustomForm(AOwner);
    end;
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
