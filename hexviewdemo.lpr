program hexviewdemo;

{$mode objfpc}{$H+}

// Multi-file demo for THexView with editing. Each open file gets its own tab
// with its own editable view (piece-table: overwrite/insert/delete, undo/redo,
// save). Devices open read-only. Built entirely in code (no .lfm).

uses
  Interfaces, Classes, SysUtils, Forms, Controls, Menus, Dialogs, ComCtrls,
  LCLType, {$IFDEF WINDOWS}Windows, ShellApi,{$ENDIF}
  ulang, uHexView, uhexcalc, uhexrsa, uhexhash, uhexchk, uhexcryptdlg,
  ufcform, uhexabout, uhexdev;

type
  { one document = one tab }
  TDocTab = class(TTabSheet)
  public
    View: THexView;
    FilePath: string;    // '' if never saved / device
    IsDevice: Boolean;
    DevPath: string;     // raw device path, when IsDevice
    DevWritable: Boolean;// device was opened for writing
    DevLocked: Boolean;  // volumes of this device were locked/dismounted
  end;

  TDemoForm = class(TForm)
  private
    FPages: TPageControl;
    FBar: TStatusBar;
    FMiInsert: TMenuItem;
    FMiHexSpaces: TMenuItem;
    FCalc: TCalcForm;
    FRsa: TRsaForm;
    FCrypto: TCryptoForm;
    FCtx: TPopupMenu;
    function ActiveDoc: TDocTab;
    function ActiveView: THexView;
    function NewTab(const ATitle: string): TDocTab;
    procedure UpdateUI;
    procedure TabTitle(ADoc: TDocTab);
    function ConfirmDiscard(ADoc: TDocTab): Boolean;
    function DoSaveInternal(ADoc: TDocTab): Boolean;
    function DoSaveAs(ADoc: TDocTab): Boolean;
    function CommitDevice(ADoc: TDocTab): Boolean;
    // menu handlers
    procedure DoOpen(Sender: TObject);
    procedure DoOpenDevice(Sender: TObject);
    procedure DoSave(Sender: TObject);
    procedure DoSaveAsMenu(Sender: TObject);
    procedure DoCloseTab(Sender: TObject);
    procedure DoExitApp(Sender: TObject);
    procedure DoUndo(Sender: TObject);
    procedure DoRedo(Sender: TObject);
    procedure DoToggleInsert(Sender: TObject);
    procedure DoDeleteSel(Sender: TObject);
    procedure DoCopyHex(Sender: TObject);
    procedure DoCopyText(Sender: TObject);
    procedure DoExportBin(Sender: TObject);
    procedure DoExportC(Sender: TObject);
    procedure DoExportPascal(Sender: TObject);
    procedure DoFindHex(Sender: TObject);
    procedure DoFindText(Sender: TObject);
    procedure DoFindNext(Sender: TObject);
    procedure DoGoto(Sender: TObject);
    procedure DoToggleUtf8(Sender: TObject);
    procedure DoBytesPerRow(Sender: TObject);
    procedure DoToggleHexSpaces(Sender: TObject);
    procedure DoCalculator(Sender: TObject);
    procedure DoRsa(Sender: TObject);
    procedure DoChecksum(Sender: TObject);
    procedure DoSaveLang(Sender: TObject);
    procedure DoReloadLang(Sender: TObject);
    procedure DoCrypto(Sender: TObject);
    procedure DoFindCrypto(Sender: TObject);
    procedure DoAbout(Sender: TObject);
    procedure DoDevDiag(Sender: TObject);
    procedure DoDevEject(Sender: TObject);
    function ActiveRawDevice: TRawDeviceByteSource;
    procedure CalcSend(AValue: Int64);
    procedure CalcClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure RsaClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure CryptoClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure Palette(f: TCustomForm);
    function GetCalc: TCalcForm;
    function GetRsa: TRsaForm;
    function GetCrypto: TCryptoForm;
    function SelHex: string;
    procedure BuildContextMenu;
    procedure CtxCopyHex(Sender: TObject);
    procedure CtxCopyText(Sender: TObject);
    procedure CtxCryptoKey(Sender: TObject);
    procedure CtxCryptoIV(Sender: TObject);
    procedure CtxRsaBase(Sender: TObject);
    procedure CtxRsaMod(Sender: TObject);
    procedure CtxRsaExp(Sender: TObject);
    procedure CtxChecksum(Sender: TObject);
    // view events
    procedure ViewSelChange(Sender: TObject);
    procedure ViewEditChange(Sender: TObject);
    procedure PagesChange(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure AddItem(AParent: TMenuItem; const ACap: string; AHandler: TNotifyEvent;
      ASC: TShortCut = 0);
    procedure AddOp(AParent: TMenuItem; const ACap: string; AOp: THexOp);
    procedure DoOp(Sender: TObject);
    function AskByte(const ATitle: string; out AVal: Integer): Boolean;
    function AskCount(const ATitle: string; out AVal: Integer): Boolean;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

procedure TDemoForm.AddItem(AParent: TMenuItem; const ACap: string;
  AHandler: TNotifyEvent; ASC: TShortCut);
var mi: TMenuItem;
begin
  mi := TMenuItem.Create(AParent);
  mi.Caption := ACap; mi.OnClick := AHandler; mi.ShortCut := ASC;
  AParent.Add(mi);
end;

procedure TDemoForm.AddOp(AParent: TMenuItem; const ACap: string; AOp: THexOp);
var mi: TMenuItem;
begin
  mi := TMenuItem.Create(AParent);
  mi.Caption := ACap; mi.OnClick := @DoOp; mi.Tag := Ord(AOp);
  AParent.Add(mi);
end;

function TDemoForm.AskByte(const ATitle: string; out AVal: Integer): Boolean;
var s: string;
begin
  Result := False; AVal := 0;
  s := '00';
  if not InputQuery(ATitle, L('dlg.operand.prompt', 'Byte value (hex, 00-FF):'), s) then Exit;
  AVal := StrToIntDef('$' + StringReplace(s, '0x', '', [rfIgnoreCase]), -1) and $FF;
  Result := True;
end;

function TDemoForm.AskCount(const ATitle: string; out AVal: Integer): Boolean;
var s: string;
begin
  Result := False; AVal := 1;
  s := '1';
  if not InputQuery(ATitle, L('dlg.shift.prompt', 'Bits (1-7):'), s) then Exit;
  AVal := StrToIntDef(s, 1) and 7;
  Result := True;
end;

procedure TDemoForm.DoOp(Sender: TObject);
var op: THexOp; operand: Integer;
begin
  if ActiveView = nil then Exit;
  if not ActiveView.IsEditable then
  begin ShowMessage(L('msg.readonly', 'This view is read-only (device).')); Exit; end;
  if ActiveView.SelCount <= 0 then
  begin ShowMessage(L('msg.selectfirst', 'Select a range first.')); Exit; end;

  op := THexOp(TComponent(Sender).Tag);
  operand := 0;
  case op of
    hopAnd, hopOr, hopXor, hopAdd, hopSub, hopMul, hopDiv, hopMod, hopFill:
      if not AskByte(L('dlg.operand.title', 'Operand'), operand) then Exit;
    hopShl, hopShr, hopRol, hopRor:
      if not AskCount(L('dlg.shift.title', 'Shift/rotate'), operand) then Exit;
  end;
  ActiveView.ApplySelectionOp(op, Byte(operand));
end;

constructor TDemoForm.CreateNew(AOwner: TComponent; Num: Integer);
var
  mm: TMainMenu;
  miFile, miEdit, miSearch, miView, miExport, miExtras, miOps, miCrypto,
  miHelp: TMenuItem;
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('app.title', 'HEXO 1.2 (VL)');
  Width := 980; Height := 660; Position := poScreenCenter;
  ShowInTaskBar := stAlways;

  mm := TMainMenu.Create(Self); Menu := mm;

  miFile := TMenuItem.Create(mm); miFile.Caption := L('menu.file', '&File'); mm.Items.Add(miFile);
  AddItem(miFile, L('menu.open', '&Open...'),        @DoOpen,       ShortCut(Ord('O'), [ssCtrl]));
  AddItem(miFile, L('menu.opendevice', 'Open &device...'), @DoOpenDevice);
  AddItem(miFile, L('menu.save', '&Save'),           @DoSave,       ShortCut(Ord('S'), [ssCtrl]));
  AddItem(miFile, L('menu.saveas', 'Save &as...'),     @DoSaveAsMenu, ShortCut(Ord('S'), [ssCtrl, ssShift]));
  AddItem(miFile, L('menu.closetab', '&Close tab'),      @DoCloseTab,   ShortCut(Ord('W'), [ssCtrl]));
  AddItem(miFile, L('menu.exit', 'E&xit'),           @DoExitApp);

  miEdit := TMenuItem.Create(mm); miEdit.Caption := L('menu.edit', '&Edit'); mm.Items.Add(miEdit);
  AddItem(miEdit, L('menu.undo', '&Undo'), @DoUndo, ShortCut(Ord('Z'), [ssCtrl]));
  AddItem(miEdit, L('menu.redo', '&Redo'), @DoRedo, ShortCut(Ord('Y'), [ssCtrl]));
  FMiInsert := TMenuItem.Create(miEdit);
  FMiInsert.Caption := L('menu.insertmode', 'Insert mode'); FMiInsert.OnClick := @DoToggleInsert;
  FMiInsert.ShortCut := ShortCut(VK_INSERT, []); miEdit.Add(FMiInsert);
  AddItem(miEdit, L('menu.delsel', 'Delete selection'), @DoDeleteSel, ShortCut(VK_DELETE, [ssCtrl]));
  AddItem(miEdit, L('menu.copyhex', 'Copy as &hex'),  @DoCopyHex,  ShortCut(Ord('C'), [ssCtrl]));
  AddItem(miEdit, L('menu.copytext', 'Copy as &text'), @DoCopyText);
  miExport := TMenuItem.Create(miEdit); miExport.Caption := L('menu.export', 'E&xport selection'); miEdit.Add(miExport);
  AddItem(miExport, L('menu.export.bin', '&Binary...'),       @DoExportBin);
  AddItem(miExport, L('menu.export.c', '&C / C++ array...'),@DoExportC);
  AddItem(miExport, L('menu.export.pascal', '&Pascal array...'), @DoExportPascal);

  miSearch := TMenuItem.Create(mm); miSearch.Caption := L('menu.search', '&Search'); mm.Items.Add(miSearch);
  AddItem(miSearch, L('menu.findhex', 'Find &hex...'),  @DoFindHex, ShortCut(Ord('F'), [ssCtrl]));
  AddItem(miSearch, L('menu.findtext', 'Find &text...'), @DoFindText);
  AddItem(miSearch, L('menu.findnext', 'Find &next'),    @DoFindNext, ShortCut(VK_F3, []));
  AddItem(miSearch, L('menu.goto', '&Goto offset...'), @DoGoto, ShortCut(Ord('G'), [ssCtrl]));

  miView := TMenuItem.Create(mm); miView.Caption := L('menu.view', '&View'); mm.Items.Add(miView);
  AddItem(miView, L('menu.utf8', 'UTF-8 char pane'), @DoToggleUtf8);
  AddItem(miView, L('menu.bpr', 'Bytes per row (8/16/32)'), @DoBytesPerRow);
  FMiHexSpaces := TMenuItem.Create(miView);
  FMiHexSpaces.Caption := L('menu.hexspaces', 'Copy hex with spaces'); FMiHexSpaces.OnClick := @DoToggleHexSpaces;
  FMiHexSpaces.Checked := True; miView.Add(FMiHexSpaces);

  miExtras := TMenuItem.Create(mm); miExtras.Caption := L('menu.extras', 'Е&кстри'); mm.Items.Add(miExtras);
  AddItem(miExtras, L('menu.calc', '&Калкулатор (hex)...'), @DoCalculator, ShortCut(VK_F2, []));
  AddItem(miExtras, L('menu.rsa', '&RSA modpow (a^b mod n)...'), @DoRsa, ShortCut(VK_F4, []));
  AddItem(miExtras, L('menu.checksum', '&Checksum / hash...'), @DoChecksum, ShortCut(VK_F6, []));
  miExtras.AddSeparator;
  AddItem(miExtras, L('menu.devdiag', '&Диагностика на записа (устройство)...'), @DoDevDiag);
  AddItem(miExtras, L('menu.deveject', 'Безопасно &изваждане на устройството'), @DoDevEject);
  miExtras.AddSeparator;
  AddItem(miExtras, L('menu.lang.save', 'Запиши &езиков шаблон (hexview.lng)'), @DoSaveLang);
  AddItem(miExtras, L('menu.lang.reload', 'Презареди &езиков файл'), @DoReloadLang);

  miCrypto := TMenuItem.Create(mm); miCrypto.Caption := L('menu.crypto', '&Крипто'); mm.Items.Add(miCrypto);
  AddItem(miCrypto, L('menu.crypto.sym', '&Symmetric (AES/3DES/DES/RC4)...'), @DoCrypto, ShortCut(VK_F7, []));
  AddItem(miCrypto, L('menu.crypto.find', '&Find crypto constants (FindCrypt)...'), @DoFindCrypto, ShortCut(VK_F8, []));

  miOps := TMenuItem.Create(mm); miOps.Caption := L('menu.ops', '&Операции'); mm.Items.Add(miOps);
  AddOp(miOps, L('op.flip', 'Byte Flip (reverse)'), hopFlip);
  AddOp(miOps, L('op.not', 'Inverse Bits (NOT)'),  hopNot);
  AddOp(miOps, L('op.neg', 'Change Sign (negate)'), hopNeg);
  miOps.AddSeparator;
  AddOp(miOps, L('op.shl', 'Shift Left...'),   hopShl);
  AddOp(miOps, L('op.shr', 'Shift Right...'),  hopShr);
  AddOp(miOps, L('op.rol', 'Rotate Left...'),  hopRol);
  AddOp(miOps, L('op.ror', 'Rotate Right...'), hopRor);
  miOps.AddSeparator;
  AddOp(miOps, L('op.and', 'AND...'), hopAnd);
  AddOp(miOps, L('op.or', 'OR...'),  hopOr);
  AddOp(miOps, L('op.xor', 'XOR...'), hopXor);
  miOps.AddSeparator;
  AddOp(miOps, L('op.add', 'Add...'),      hopAdd);
  AddOp(miOps, L('op.sub', 'Subtract...'), hopSub);
  AddOp(miOps, L('op.mul', 'Multiply...'), hopMul);
  AddOp(miOps, L('op.div', 'Divide...'),   hopDiv);
  AddOp(miOps, L('op.mod', 'Mod...'),      hopMod);
  miOps.AddSeparator;
  AddOp(miOps, L('op.upper', 'Upper Case'),   hopUpper);
  AddOp(miOps, L('op.lower', 'Lower Case'),   hopLower);
  AddOp(miOps, L('op.invcase', 'Inverse Case'), hopInvCase);
  miOps.AddSeparator;
  AddOp(miOps, L('op.fill', 'Fill...'), hopFill);

  miHelp := TMenuItem.Create(mm); miHelp.Caption := L('menu.help', '&Помощ'); mm.Items.Add(miHelp);
  AddItem(miHelp, L('menu.about', '&Относно...'), @DoAbout, ShortCut(VK_F1, []));

  FBar := TStatusBar.Create(Self); FBar.Parent := Self; FBar.SimplePanel := True;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self; FPages.Align := alClient; FPages.OnChange := @PagesChange;

  BuildContextMenu;

  OnCloseQuery := @FormCloseQuery;
  OnClose := @FormClose;
end;

function TDemoForm.ActiveDoc: TDocTab;
begin
  if (FPages.ActivePage <> nil) and (FPages.ActivePage is TDocTab) then
    Result := TDocTab(FPages.ActivePage)
  else
    Result := nil;
end;

function TDemoForm.ActiveView: THexView;
var d: TDocTab;
begin
  d := ActiveDoc;
  if Assigned(d) then Result := d.View else Result := nil;
end;

function TDemoForm.NewTab(const ATitle: string): TDocTab;
begin
  Result := TDocTab.Create(FPages);
  Result.PageControl := FPages;
  Result.Caption := ATitle;
  Result.View := THexView.Create(Result);
  Result.View.Parent := Result;
  Result.View.Align := alClient;
  Result.View.OnSelChange := @ViewSelChange;
  Result.View.OnEditChange := @ViewEditChange;
  Result.View.PopupMenu := FCtx;
  FPages.ActivePage := Result;
end;

procedure TDemoForm.TabTitle(ADoc: TDocTab);
var t: string;
begin
  if ADoc.FilePath <> '' then t := ExtractFileName(ADoc.FilePath)
  else if ADoc.IsDevice then
  begin
    t := ADoc.DevPath;
    // a tab that can write to a raw disk says so, always
    if not ADoc.DevWritable then t := t + ' [RO]'
    else if ADoc.DevLocked then t := t + ' [RW+L]'
    else t := t + ' [RW]';
  end
  else t := L('tab.untitled', 'untitled');
  if Assigned(ADoc.View) and ADoc.View.IsModified then t := '*' + t;
  ADoc.Caption := t;
end;

procedure TDemoForm.UpdateUI;
var v: THexView; mode, modf, dev: string;
begin
  v := ActiveView;
  if v = nil then begin FBar.SimpleText := L('status.nofile', 'No file open'); Exit; end;
  if v.InsertMode then mode := L('status.ins', 'INS') else mode := L('status.ovr', 'OVR');
  if v.IsModified then modf := L('status.mod', '  [MOD]') else modf := '';
  dev := '';
  if Assigned(ActiveDoc) and ActiveDoc.IsDevice then
    if ActiveDoc.DevWritable then dev := L('status.devrw', '   ДИСК: ЗАПИС РАЗРЕШЕН')
    else dev := L('status.devro', '   ДИСК: само четене');
  FBar.SimpleText := Format(L('status.fmt', 'Pos: 0x%s   Size: 0x%s   Sel: %d   %s%s'),
    [IntToHex(v.CursorPos, 8), IntToHex(v.DataSize, 8), v.SelCount, mode, modf]) + dev;
  FMiInsert.Checked := v.InsertMode;
  FMiHexSpaces.Checked := v.HexCopySpaces;
  if Assigned(ActiveDoc) then TabTitle(ActiveDoc);
end;

function TDemoForm.ConfirmDiscard(ADoc: TDocTab): Boolean;
begin
  Result := True;
  if Assigned(ADoc) and Assigned(ADoc.View) and ADoc.View.IsModified then
    case MessageDlg(Format(L('msg.savechanges', 'Save changes to %s?'), [ADoc.Caption]),
      mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
      mrYes:    Result := DoSaveInternal(ADoc);
      mrNo:     Result := True;
      mrCancel: Result := False;
    end;
end;

function TDemoForm.CommitDevice(ADoc: TDocTab): Boolean;
var
  v: THexView;
  r: TModRanges;
  i, shown: Integer;
  det, msg, typed, magic, warn: string;
  total: Int64;
  src: TByteSource;
begin
  Result := False;
  v := ADoc.View;
  if (v = nil) or not v.CanCommit then
  begin
    ShowMessage(L('dev.ro', 'Устройството е отворено само за четене.'));
    Exit;
  end;

  r := v.ModifiedRanges;
  if Length(r) = 0 then
  begin
    ShowMessage(L('dev.nochanges', 'Няма промени за записване.'));
    Exit;
  end;
  total := v.ModifiedByteCount;

  // spell out exactly which sectors are about to change
  det := '';
  shown := Length(r);
  if shown > 8 then shown := 8;
  for i := 0 to shown - 1 do
    det := det + Format('    0x%s .. 0x%s   (%d B)',
      [IntToHex(r[i].Start, 8), IntToHex(r[i].Start + r[i].Len - 1, 8), r[i].Len])
      + LineEnding;
  if Length(r) > shown then
    det := det + Format(L('dev.more', '    ... и още %d диапазона'),
      [Length(r) - shown]) + LineEnding;

  // is any of this inside a volume Windows still has mounted?
  warn := '';
  src := v.Source;
  if src is TEditByteSource then src := TEditByteSource(src).Backing;
  if src is TRawDeviceByteSource then
    if not TRawDeviceByteSource(src).Exclusive then
      for i := 0 to Length(r) - 1 do
        if TRawDeviceByteSource(src).InMountedVolume(r[i].Start) then
        begin
          warn := LineEnding + LineEnding + L('dev.mounted',
            'ВНИМАНИЕ: част от диапазоните са в дял, който Windows държи' +
            LineEnding + 'монтиран, а дяловете не са заключени. Записът там' +
            LineEnding + 'може да бъде отменен от файловата система. За такава' +
            LineEnding + 'редакция отвори устройството наново с "Запис +' +
            LineEnding + 'заключване на дяловете".');
          Break;
        end;

  { ---- потвърждение 1 от 2 ---- }
  msg := Format(L('dev.warn1',
    'На път си да запишеш направо върху %s.' + LineEnding + LineEnding +
    '%d диапазона, общо %d байта:'), [ADoc.DevPath, Length(r), total]) +
    LineEnding + det + LineEnding +
    L('dev.warn1b',
      'Това е НЕОБРАТИМО. Няма undo след записа.') + warn;
  if QuestionDlg(L('dev.title', 'Запис върху устройство (1 от 2)'), msg, mtWarning,
       [mrNo,  L('dev.cancel', 'Отказ'), 'IsDefault',
        mrYes, L('dev.go', 'Продължи')], 0) <> mrYes then Exit;

  { ---- потвърждение 2 от 2 ---- }
  magic := L('dev.word', 'ЗАПИШИ');
  typed := '';
  if not InputQuery(L('dev.title2', 'Запис върху устройство (2 от 2)'),
       Format(L('dev.warn2',
         'Последно потвърждение за %s.' + LineEnding +
         'Напиши %s и натисни OK:'), [ADoc.DevPath, magic]), typed) then Exit;
  if UpperCase(Trim(typed)) <> UpperCase(magic) then
  begin
    ShowMessage(L('dev.notconfirmed', 'Не е потвърдено - нищо не е записано.'));
    Exit;
  end;

  try
    v.CommitToBacking;
    Result := True;
    ShowMessage(Format(L('dev.done', 'Записани %d байта в %d диапазона.'),
      [total, Length(r)]));
  except
    // wrote "fine" but the device gave the old bytes back - the one failure
    // mode that must never look like success
    on E: EHexVerify do
      ShowMessage(Format(L('dev.verifyfail',
        'Записът НЕ се потвърди на офсет 0x%s.' + LineEnding +
        'Устройството върна старите байтове - дискът НЕ е променен.' +
        LineEnding + LineEnding +
        'Възможни причини:' + LineEnding +
        '- флашката/дискът е защитен от запис (ключе или контролер);' + LineEnding +
        '- Windows пази секторите на монтиран дял - затвори програмите, които' +
        LineEnding +
        '  ползват диска, или го размонтирай от Управление на дисковете;' +
        LineEnding +
        '- програмата не е стартирана като администратор.'),
        [IntToHex(E.Offset, 8)]));
    on E: Exception do
      ShowMessage(L('dev.failed', 'Записът се провали:') + LineEnding + E.Message);
  end;
  TabTitle(ADoc);
  UpdateUI;
end;

function TDemoForm.DoSaveInternal(ADoc: TDocTab): Boolean;
begin
  if (ADoc = nil) or (ADoc.View = nil) then Exit(False);
  if ADoc.IsDevice then Exit(CommitDevice(ADoc));
  if not ADoc.View.IsEditable then
  begin ShowMessage(L('msg.readonly', 'This view is read-only (device).')); Exit(False); end;
  if ADoc.FilePath = '' then
    Result := DoSaveAs(ADoc)
  else
  begin
    ADoc.View.SaveToFile(ADoc.FilePath);
    TabTitle(ADoc);
    Result := True;
  end;
end;

function TDemoForm.DoSaveAs(ADoc: TDocTab): Boolean;
var dlg: TSaveDialog;
begin
  Result := False;
  dlg := TSaveDialog.Create(Self);
  try
    if ADoc.FilePath <> '' then dlg.FileName := ADoc.FilePath;
    if dlg.Execute then
    begin
      ADoc.View.SaveToFile(dlg.FileName);
      ADoc.FilePath := dlg.FileName;
      ADoc.IsDevice := False;
      TabTitle(ADoc);
      Result := True;
    end;
  finally
    dlg.Free;
  end;
end;

procedure TDemoForm.DoOpen(Sender: TObject);
var dlg: TOpenDialog; d: TDocTab;
begin
  dlg := TOpenDialog.Create(Self);
  try
    if dlg.Execute then
    begin
      d := NewTab(ExtractFileName(dlg.FileName));
      d.FilePath := dlg.FileName;
      d.View.OpenEditable(dlg.FileName, False);
      TabTitle(d);
      d.View.SetFocus;
      UpdateUI;
    end;
  finally
    dlg.Free;
  end;
end;

{$IFDEF WINDOWS}
// start another copy of ourselves with the "runas" verb, which is what makes
// Windows put up the elevation prompt
function RelaunchElevated: Boolean;
begin
  Result := ShellExecuteW(0, PWideChar(WideString('runas')),
    PWideChar(WideString(ParamStr(0))), nil, nil, SW_SHOWNORMAL) > 32;
end;
{$ENDIF}

procedure TDemoForm.DoOpenDevice(Sender: TObject);
var
  s: string;
  d: TDocTab;
  mode: Integer;
  wr, lockVols: Boolean;

  function TryOpen(AWritable, ALock: Boolean): Boolean;
  begin
    Result := False;
    d := NewTab(s);
    d.IsDevice := True;
    d.DevPath := s;
    d.DevWritable := AWritable;
    d.DevLocked := AWritable and ALock;
    try
      d.View.OpenDevice(s, AWritable, ALock);
      TabTitle(d);
      d.View.SetFocus;
      UpdateUI;
      Result := True;
    except
      // access denied on a raw device means one thing in practice
      on E: EHexOpen do
      begin
        FreeAndNil(d);
        {$IFDEF WINDOWS}
        if E.Code = 5 then
        begin
          if QuestionDlg(L('dev.admin.title', 'Нужни са администраторски права'),
               Format(L('dev.admin.msg',
                 'Windows отказа достъп до %s (грешка 5).' + LineEnding +
                 LineEnding +
                 'Суровият достъп до физически диск иска програмата да е' +
                 LineEnding + 'стартирана като администратор.' + LineEnding +
                 LineEnding + 'Да я пусна наново с администраторски права?'),
                 [s]),
               mtWarning,
               [mrYes, L('dev.admin.relaunch', 'Пусни като администратор'),
                'IsDefault', mrNo, L('dev.cancel', 'Отказ')], 0) = mrYes then
            if RelaunchElevated then Close
            else
              ShowMessage(L('dev.admin.failed',
                'Стартирането с администраторски права беше отказано.'));
          Exit;
        end;
        {$ENDIF}
        ShowMessage(E.Message);
      end;
      on E: Exception do
      begin
        FreeAndNil(d);
        ShowMessage(E.Message);
      end;
    end;
  end;

begin
  // pick from the drives the machine actually has, instead of typing a path
  if not SelectDevice(Self, s) then Exit;
  if Trim(s) = '' then Exit;

  // read-only is the default answer; writing to a raw disk is opt-in
  mode := QuestionDlg(L('dlg.devmode.title', 'Режим на отваряне'),
          Format(L('dlg.devmode.msg',
            'Как да отворя %s?' + LineEnding + LineEnding +
            'Записът върху сурово устройство променя диска НЕОБРАТИМО.' +
            LineEnding + 'Избери "Само за четене", ако не си сигурен.'), [s]),
          mtWarning,
          [mrNo,  L('dlg.devmode.ro', 'Само за четене'), 'IsDefault',
           mrYes, L('dlg.devmode.rw', 'Четене и ЗАПИС'),
           mrAll, L('dlg.devmode.rwlock', 'Запис + заключване на дяловете')], 0);
  if mode = mrCancel then Exit;
  wr := mode in [mrYes, mrAll];
  // Locking is OFF by default: locking a volume and letting it go makes
  // Windows re-mount it, and the re-mount puts the old bytes back over areas
  // outside the volume (the MBR gap, most of all). Lock only on request, for
  // edits that really live inside a mounted volume.
  lockVols := mode = mrAll;

  if TryOpen(wr, lockVols) then Exit;

  // couldn't open writable (usually: not running as administrator)
  if wr then
    if QuestionDlg(L('dlg.devmode.title', 'Режим на отваряне'),
         L('dlg.devfallback',
           'Устройството не може да се отвори за запис.' + LineEnding +
           'Да го отворя само за четене?'),
         mtWarning,
         [mrYes, L('btn.yes', 'Да'), 'IsDefault', mrNo, L('btn.no', 'Не')], 0) = mrYes then
      TryOpen(False, False);
end;

procedure TDemoForm.DoSave(Sender: TObject);
begin
  if ActiveView = nil then Exit;
  DoSaveInternal(ActiveDoc);
end;

procedure TDemoForm.DoSaveAsMenu(Sender: TObject);
begin
  if ActiveView = nil then Exit;
  // "save as" on a device would dump the whole disk into a file
  if ActiveDoc.IsDevice then
  begin
    ShowMessage(L('msg.devicesaveas',
      'Устройство не се записва като файл.' + LineEnding +
      'Маркирай диапазон и ползвай Редакция -> Експорт.'));
    Exit;
  end;
  DoSaveAs(ActiveDoc);
end;

procedure TDemoForm.DoCloseTab(Sender: TObject);
var d: TDocTab;
begin
  d := ActiveDoc;
  if d = nil then Exit;
  if not ConfirmDiscard(d) then Exit;
  d.Free;
  UpdateUI;
end;

procedure TDemoForm.DoExitApp(Sender: TObject);
begin
  Close;
end;

procedure TDemoForm.DoUndo(Sender: TObject);
begin if ActiveView <> nil then ActiveView.Undo; end;

procedure TDemoForm.DoRedo(Sender: TObject);
begin if ActiveView <> nil then ActiveView.Redo; end;

procedure TDemoForm.DoToggleInsert(Sender: TObject);
begin
  if ActiveView <> nil then
  begin
    ActiveView.InsertMode := not ActiveView.InsertMode;
    ActiveView.SetFocus;
    UpdateUI;
  end;
end;

procedure TDemoForm.DoDeleteSel(Sender: TObject);
begin if ActiveView <> nil then ActiveView.DeleteSelection; end;

procedure TDemoForm.DoCopyHex(Sender: TObject);
begin if ActiveView <> nil then ActiveView.CopySelectionHex; end;

procedure TDemoForm.DoCopyText(Sender: TObject);
begin if ActiveView <> nil then ActiveView.CopySelectionText; end;

procedure TDemoForm.DoExportBin(Sender: TObject);
var dlg: TSaveDialog;
begin
  if (ActiveView = nil) or (ActiveView.SelCount <= 0) then
  begin ShowMessage(L('msg.selectfirst', 'Select a range first.')); Exit; end;
  dlg := TSaveDialog.Create(Self);
  try dlg.DefaultExt := 'bin'; if dlg.Execute then ActiveView.ExportSelectionBin(dlg.FileName);
  finally dlg.Free; end;
end;

procedure TDemoForm.DoExportC(Sender: TObject);
var dlg: TSaveDialog; vn: string;
begin
  if (ActiveView = nil) or (ActiveView.SelCount <= 0) then
  begin ShowMessage(L('msg.selectfirst', 'Select a range first.')); Exit; end;
  vn := 'data';
  if not InputQuery(L('dlg.expc.title', 'Export C array'), L('dlg.expc.prompt', 'Variable name:'), vn) then Exit;
  dlg := TSaveDialog.Create(Self);
  try dlg.DefaultExt := 'h'; if dlg.Execute then ActiveView.ExportSelectionC(dlg.FileName, vn);
  finally dlg.Free; end;
end;

procedure TDemoForm.DoExportPascal(Sender: TObject);
var dlg: TSaveDialog; vn: string;
begin
  if (ActiveView = nil) or (ActiveView.SelCount <= 0) then
  begin ShowMessage(L('msg.selectfirst', 'Select a range first.')); Exit; end;
  vn := 'Data';
  if not InputQuery(L('dlg.expp.title', 'Export Pascal array'), L('dlg.expp.prompt', 'Constant name:'), vn) then Exit;
  dlg := TSaveDialog.Create(Self);
  try dlg.DefaultExt := 'pas'; if dlg.Execute then ActiveView.ExportSelectionPascal(dlg.FileName, vn);
  finally dlg.Free; end;
end;

procedure TDemoForm.DoFindHex(Sender: TObject);
var s: string; pat: TBytes;
begin
  if ActiveView = nil then Exit;
  s := '';
  if not InputQuery(L('dlg.findhex.title', 'Find hex'), L('dlg.findhex.prompt', 'Hex bytes (e.g. DE AD BE EF):'), s) then Exit;
  if not THexView.ParseHexPattern(s, pat) then begin ShowMessage(L('msg.badhex', 'Invalid hex pattern.')); Exit; end;
  if not ActiveView.FindFirst(pat[0], Length(pat), False) then ShowMessage(L('msg.notfound', 'Not found.'));
end;

procedure TDemoForm.DoFindText(Sender: TObject);
var s: string;
begin
  if ActiveView = nil then Exit;
  s := '';
  if not InputQuery(L('dlg.findtext.title', 'Find text'), L('dlg.findtext.prompt', 'Text (UTF-8):'), s) then Exit;
  if s = '' then Exit;
  if not ActiveView.FindFirst(s[1], Length(s), False) then ShowMessage(L('msg.notfound', 'Not found.'));
end;

procedure TDemoForm.DoFindNext(Sender: TObject);
begin
  if ActiveView = nil then Exit;
  if not ActiveView.FindNext then ShowMessage(L('msg.nomore', 'No more matches.'));
end;

procedure TDemoForm.DoGoto(Sender: TObject);
var s: string; ofs: Int64;
begin
  if ActiveView = nil then Exit;
  s := '0';
  if not InputQuery(L('dlg.goto.title', 'Goto offset'), L('dlg.goto.prompt', 'Offset (hex):'), s) then Exit;
  ofs := StrToInt64Def('$' + StringReplace(s, '0x', '', [rfIgnoreCase]), -1);
  if ofs < 0 then begin ShowMessage(L('msg.badoffset', 'Invalid offset.')); Exit; end;
  ActiveView.GotoOffset(ofs);
end;

procedure TDemoForm.DoToggleUtf8(Sender: TObject);
begin if ActiveView <> nil then ActiveView.Utf8CharPane := not ActiveView.Utf8CharPane; end;

procedure TDemoForm.DoBytesPerRow(Sender: TObject);
begin
  if ActiveView = nil then Exit;
  case ActiveView.BytesPerRow of
    16: ActiveView.BytesPerRow := 32;
    32: ActiveView.BytesPerRow := 8;
  else  ActiveView.BytesPerRow := 16;
  end;
end;

procedure TDemoForm.DoToggleHexSpaces(Sender: TObject);
begin
  if ActiveView = nil then Exit;
  ActiveView.HexCopySpaces := not ActiveView.HexCopySpaces;
  FMiHexSpaces.Checked := ActiveView.HexCopySpaces;
end;

procedure TDemoForm.Palette(f: TCustomForm);
begin
  f.ShowInTaskBar := stNever;
  f.PopupMode := pmExplicit;
  f.PopupParent := Self;
end;

function TDemoForm.GetCalc: TCalcForm;
begin
  if FCalc = nil then
  begin
    FCalc := TCalcForm.CreateNew(Self);
    FCalc.OnSend := @CalcSend;
    FCalc.OnClose := @CalcClosed;
    Palette(FCalc);
  end;
  Result := FCalc;
end;

function TDemoForm.GetRsa: TRsaForm;
begin
  if FRsa = nil then
  begin
    FRsa := TRsaForm.CreateNew(Self);
    FRsa.OnClose := @RsaClosed;
    Palette(FRsa);
  end;
  Result := FRsa;
end;

function TDemoForm.GetCrypto: TCryptoForm;
begin
  if FCrypto = nil then
  begin
    FCrypto := TCryptoForm.CreateNew(Self);
    FCrypto.OnClose := @CryptoClosed;
    Palette(FCrypto);
  end;
  Result := FCrypto;
  Result.View := ActiveView;
end;

procedure TDemoForm.DoCalculator(Sender: TObject);
begin
  GetCalc;
  if not FCalc.Visible then FCalc.Show;
  FCalc.BringToFront;
end;

procedure TDemoForm.CalcSend(AValue: Int64);
begin
  if ActiveView <> nil then ActiveView.GotoOffset(AValue);
end;

procedure TDemoForm.CalcClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  FCalc := nil;
end;

procedure TDemoForm.RsaClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  FRsa := nil;
end;

procedure TDemoForm.CryptoClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  FCrypto := nil;
end;

function TDemoForm.SelHex: string;
var b: TBytes; i: Integer;
begin
  Result := '';
  if (ActiveView = nil) or (ActiveView.SelCount <= 0) then Exit;
  if ActiveView.SelCount > 1024 * 1024 then Exit;   // sanity cap
  b := ActiveView.ReadSelection;
  for i := 0 to High(b) do Result := Result + IntToHex(b[i], 2);
end;

procedure TDemoForm.DoRsa(Sender: TObject);
begin
  GetRsa;
  if SelHex <> '' then FRsa.SetBaseHex(SelHex);
  if not FRsa.Visible then FRsa.Show;
  FRsa.BringToFront;
end;

procedure TDemoForm.DoChecksum(Sender: TObject);
var v: THexView; start, len: Int64; cap: string;
begin
  v := ActiveView;
  if (v = nil) or (v.Source = nil) or (v.DataSize <= 0) then
  begin ShowMessage(L('msg.openfirst', 'Open a file first.')); Exit; end;
  if v.SelCount > 0 then
  begin
    start := v.SelStart; len := v.SelCount;
    cap := Format(L('chk.range.sel', 'Selection: 0x%s .. 0x%s  (%d bytes)'),
      [IntToHex(v.SelStart, 8), IntToHex(v.SelEnd, 8), v.SelCount]);
  end
  else
  begin
    start := 0; len := v.DataSize;
    cap := Format(L('chk.range.all', 'Whole file: %d bytes'), [v.DataSize]);
  end;
  ShowChecksums(Self, @v.Source.ReadAt, start, len, cap);
end;

procedure TDemoForm.DoAbout(Sender: TObject);
begin
  ShowAbout(Self);
end;

// the raw source sits under the edit layer when the device is writable
function TDemoForm.ActiveRawDevice: TRawDeviceByteSource;
var d: TDocTab; src: TByteSource;
begin
  Result := nil;
  d := ActiveDoc;
  if (d = nil) or (not d.IsDevice) or (d.View = nil) then Exit;
  src := d.View.Source;
  if src is TEditByteSource then src := TEditByteSource(src).Backing;
  if src is TRawDeviceByteSource then Result := TRawDeviceByteSource(src);
end;

procedure TDemoForm.DoDevEject(Sender: TObject);
var dev: TRawDeviceByteSource;
begin
  dev := ActiveRawDevice;
  if dev = nil then
  begin
    ShowMessage(L('diag.nodev',
      'Отвори устройство първо (Файл -> Отвори устройство).'));
    Exit;
  end;
  ShowMessage(dev.EjectDevice);
end;

procedure TDemoForm.DoDevDiag(Sender: TObject);
var
  d: TDocTab;
  dev: TRawDeviceByteSource;
  rep: string;
begin
  d := ActiveDoc;
  dev := ActiveRawDevice;
  if (d = nil) or (dev = nil) then
  begin
    ShowMessage(L('diag.nodev',
      'Отвори устройство първо (Файл -> Отвори устройство).'));
    Exit;
  end;

  if dev.CanWrite then
    if QuestionDlg(L('diag.title', 'Диагностика на записа'),
         Format(L('diag.warn',
           'Тестът ще обърне ЕДИН байт на 0x%s и веднага ще го върне обратно.' +
           LineEnding + 'Прави се върху %s.' + LineEnding + LineEnding +
           'Да продължа?'),
           [IntToHex((d.View.CursorPos div 512) * 512, 8), d.DevPath]),
         mtWarning,
         [mrNo, L('dev.cancel', 'Отказ'), 'IsDefault',
          mrYes, L('dev.go', 'Продължи')], 0) <> mrYes then Exit;

  rep := dev.Diagnose(d.View.CursorPos);
  ShowReport(Self, L('diag.title', 'Диагностика на записа'), rep);
end;

procedure TDemoForm.DoSaveLang(Sender: TObject);
begin
  LangSaveTemplate(LangFileName);
  ShowMessage(Format(L('msg.lang.saved',
    'Записан: %s' + LineEnding + LineEnding +
    'Редактирай дясната страна на всеки ред и рестартирай.'), [LangFileName]));
end;

procedure TDemoForm.DoReloadLang(Sender: TObject);
begin
  LangLoadFile(LangFileName);
  ShowMessage(L('msg.lang.reloaded',
    'Езиковият файл е презареден. Рестартирай, за да се обновят менютата.'));
end;

procedure TDemoForm.DoCrypto(Sender: TObject);
begin
  if ActiveView = nil then begin ShowMessage(L('msg.openfirst', 'Open a file first.')); Exit; end;
  GetCrypto;
  if not FCrypto.Visible then FCrypto.Show;
  FCrypto.BringToFront;
end;

{ context menu (right-click on the hex view) }

procedure TDemoForm.DoFindCrypto(Sender: TObject);
begin
  if (ActiveView = nil) or (ActiveView.DataSize <= 0) then
  begin ShowMessage(L('msg.openfirst', 'Open a file first.')); Exit; end;
  ShowFindCrypto(Self, ActiveView);
end;

procedure TDemoForm.BuildContextMenu;
  procedure Add(AParent: TMenuItem; const c: string; h: TNotifyEvent);
  var mi: TMenuItem;
  begin mi := TMenuItem.Create(FCtx); mi.Caption := c; mi.OnClick := h; AParent.Add(mi); end;
var mCrypto, mRsa: TMenuItem;
begin
  FCtx := TPopupMenu.Create(Self);
  Add(FCtx.Items, L('ctx.copyhex', 'Copy as hex'), @CtxCopyHex);
  Add(FCtx.Items, L('ctx.copytext', 'Copy as text'), @CtxCopyText);
  FCtx.Items.AddSeparator;

  mCrypto := TMenuItem.Create(FCtx); mCrypto.Caption := L('ctx.crypto', 'Изпрати в Крипто'); FCtx.Items.Add(mCrypto);
  Add(mCrypto, L('ctx.crypto.key', 'Като ключ'), @CtxCryptoKey);
  Add(mCrypto, L('ctx.crypto.iv', 'Като IV'), @CtxCryptoIV);

  mRsa := TMenuItem.Create(FCtx); mRsa.Caption := L('ctx.rsa', 'Изпрати в RSA'); FCtx.Items.Add(mRsa);
  Add(mRsa, L('ctx.rsa.base', 'Като Base'), @CtxRsaBase);
  Add(mRsa, L('ctx.rsa.mod', 'Като Modulus'), @CtxRsaMod);
  Add(mRsa, L('ctx.rsa.exp', 'Като Exponent'), @CtxRsaExp);

  FCtx.Items.AddSeparator;
  Add(FCtx.Items, L('ctx.checksum', 'Checksum на селекцията'), @CtxChecksum);
end;

procedure TDemoForm.CtxCopyHex(Sender: TObject);
begin if ActiveView <> nil then ActiveView.CopySelectionHex; end;

procedure TDemoForm.CtxCopyText(Sender: TObject);
begin if ActiveView <> nil then ActiveView.CopySelectionText; end;

procedure TDemoForm.CtxCryptoKey(Sender: TObject);
var h: string;
begin
  h := SelHex; if h = '' then Exit;
  GetCrypto.SetKeyHex(h);
  if not FCrypto.Visible then FCrypto.Show;
  FCrypto.BringToFront;
end;

procedure TDemoForm.CtxCryptoIV(Sender: TObject);
var h: string;
begin
  h := SelHex; if h = '' then Exit;
  GetCrypto.SetIVHex(h);
  if not FCrypto.Visible then FCrypto.Show;
  FCrypto.BringToFront;
end;

procedure TDemoForm.CtxRsaBase(Sender: TObject);
var h: string;
begin
  h := SelHex; if h = '' then Exit;
  GetRsa.SetBaseHex(h);
  if not FRsa.Visible then FRsa.Show;
  FRsa.BringToFront;
end;

procedure TDemoForm.CtxRsaMod(Sender: TObject);
var h: string;
begin
  h := SelHex; if h = '' then Exit;
  GetRsa.SetModulusHex(h);
  if not FRsa.Visible then FRsa.Show;
  FRsa.BringToFront;
end;

procedure TDemoForm.CtxRsaExp(Sender: TObject);
var h: string;
begin
  h := SelHex; if h = '' then Exit;
  GetRsa.SetExpHex(h);
  if not FRsa.Visible then FRsa.Show;
  FRsa.BringToFront;
end;

procedure TDemoForm.CtxChecksum(Sender: TObject);
begin
  DoChecksum(Sender);
end;

procedure TDemoForm.ViewSelChange(Sender: TObject);
begin UpdateUI; end;

procedure TDemoForm.ViewEditChange(Sender: TObject);
begin UpdateUI; end;

procedure TDemoForm.PagesChange(Sender: TObject);
begin
  if ActiveView <> nil then ActiveView.SetFocus;
  UpdateUI;
end;

procedure TDemoForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var i: Integer;
begin
  CanClose := True;
  for i := FPages.PageCount - 1 downto 0 do
    if FPages.Pages[i] is TDocTab then
    begin
      FPages.ActivePageIndex := i;
      if not ConfirmDiscard(TDocTab(FPages.Pages[i])) then
      begin CanClose := False; Exit; end;
    end;
end;

procedure TDemoForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseAction := caFree;
  Application.Terminate;
end;

var
  F: TDemoForm;
begin
  Application.Initialize;
  Application.Title := 'THexView';
  LangLoadFile(LangFileName);
  F := TDemoForm.CreateNew(Application);
  F.Show;
  Application.Run;
end.
