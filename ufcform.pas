unit ufcform;

{$mode objfpc}{$H+}

// "Find crypto constants" dialog. Pick ONE algorithm, optionally limit to the
// selection, scan, jump to a hit by double-click. The scan runs in a worker
// thread (with its own file handle) for file-backed views; a progress bar sits
// under the list and a Cancel stops it. Non-file / modified views fall back to
// a main-thread scan with ProcessMessages.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, CheckLst, ComCtrls, Graphics,
  uHexView, ufindcrypt, ulang;

procedure ShowFindCrypto(AOwner: TComponent; AView: THexView);

implementation

type
  TFCForm = class;

  // worker thread: opens its own read-only stream on the file
  TScanThread = class(TThread)
  private
    FForm: TFCForm;
    FFileName: string;
    FAlgos: TStringList;
    FStart, FLen: Int64;
    FHits: TFCHits;
    FCount: Integer;
    FCurPos, FTotal: Int64;
    FStream: TFileStream;
    function Read(APos: Int64; var ABuf; ALen: Integer): Integer;
    procedure SyncProgress;
    procedure SyncDone;
    procedure ProgressCB(APos, ATotal: Int64);
  public
    Cancel: Boolean;
    constructor Create(AForm: TFCForm; const AFile: string; AAlgos: TStringList; AStart, ALen: Int64);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  TFCForm = class(TForm)
  private
    FView: THexView;
    FAlgo: TCheckListBox;
    FAllChk: TCheckBox;
    FSelOnly: TCheckBox;
    FSum: TLabel;
    FList: TListView;
    FProg: TProgressBar;
    FBtn: TButton;
    FHits: TFCHits;
    FThread: TScanThread;
    FMainCancel: Boolean;
    FRunning: Boolean;
    procedure DoScan(Sender: TObject);
    procedure DoDblClick(Sender: TObject);
    procedure MainProgress(APos, ATotal: Int64);
    procedure SetRunning(AOn: Boolean);
    procedure ShowHits(ACount: Integer; const AHits: TFCHits; AStart, ALen: Int64; ACancelled: Boolean);
    procedure BeginScan;
    procedure FCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

{ ---- thread ---- }

constructor TScanThread.Create(AForm: TFCForm; const AFile: string; AAlgos: TStringList; AStart, ALen: Int64);
begin
  inherited Create(True);            // suspended
  FreeOnTerminate := True;
  FForm := AForm; FFileName := AFile; FStart := AStart; FLen := ALen;
  FAlgos := TStringList.Create;
  if AAlgos <> nil then FAlgos.Assign(AAlgos);
end;

destructor TScanThread.Destroy;
begin
  FAlgos.Free;
  inherited Destroy;
end;

function TScanThread.Read(APos: Int64; var ABuf; ALen: Integer): Integer;
begin
  FStream.Position := APos;
  Result := FStream.Read(ABuf, ALen);
end;

procedure TScanThread.ProgressCB(APos, ATotal: Int64);
begin
  FCurPos := APos; FTotal := ATotal;
  Synchronize(@SyncProgress);
end;

procedure TScanThread.SyncProgress;
begin
  if FTotal > 0 then FForm.FProg.Position := Round(FCurPos / FTotal * 1000);
end;

procedure TScanThread.SyncDone;
begin
  FForm.FThread := nil;
  FForm.ShowHits(FCount, FHits, FStart, FLen, Cancel);
end;

procedure TScanThread.Execute;
begin
  try
    FStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyNone);
    try
      FCount := FindCryptoMulti(@Read, FStart, FLen, FHits, FAlgos, @ProgressCB, @Cancel);
    finally
      FStream.Free;
    end;
  except
    FCount := 0; FHits := nil;
  end;
  Synchronize(@SyncDone);
end;

{ ---- form ---- }

constructor TFCForm.CreateNew(AOwner: TComponent; Num: Integer);
var c: TListColumn; algos: TStringList;
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('fc.title', 'Find crypto constants');
  Position := poScreenCenter;
  ClientWidth := 600; ClientHeight := 470;

  with TLabel.Create(Self) do
  begin Parent := Self; SetBounds(12, 12, 200, 18); Caption := L('fc.algos', 'Algorithms (check one or more):'); end;

  FAlgo := TCheckListBox.Create(Self); FAlgo.Parent := Self;
  FAlgo.SetBounds(12, 32, 200, 220);
  FAlgo.Anchors := [akLeft, akTop, akBottom];
  algos := FCAlgoNames;
  try
    FAlgo.Items.AddStrings(algos);
  finally
    algos.Free;
  end;

  FAllChk := TCheckBox.Create(Self); FAllChk.Parent := Self;
  FAllChk.SetBounds(12, 258, 200, 22);
  FAllChk.Anchors := [akLeft, akBottom];
  FAllChk.Caption := L('fc.all2', 'All (slow on big files)');

  FSelOnly := TCheckBox.Create(Self); FSelOnly.Parent := Self;
  FSelOnly.SetBounds(228, 32, 200, 22); FSelOnly.Caption := L('fc.selonly', 'Selection only');

  FBtn := TButton.Create(Self); FBtn.Parent := Self;
  FBtn.SetBounds(228, 62, 130, 30);
  FBtn.Caption := L('fc.scan', 'Scan'); FBtn.OnClick := @DoScan; FBtn.Default := True;

  FSum := TLabel.Create(Self); FSum.Parent := Self; FSum.SetBounds(228, 104, 360, 18);

  FList := TListView.Create(Self);
  FList.Parent := Self; FList.SetBounds(12, 290, 576, 148);
  FList.Anchors := [akLeft, akTop, akRight, akBottom];
  FList.ViewStyle := vsReport; FList.ReadOnly := True; FList.RowSelect := True;
  FList.OnDblClick := @DoDblClick;
  c := FList.Columns.Add; c.Caption := L('fc.col.offset', 'Offset');  c.Width := 130;
  c := FList.Columns.Add; c.Caption := L('fc.col.algo', 'Algorithm'); c.Width := 120;
  c := FList.Columns.Add; c.Caption := L('fc.col.sig', 'Signature');  c.Width := 240;
  c := FList.Columns.Add; c.Caption := L('fc.col.bytes', 'Bytes');    c.Width := 80;

  FProg := TProgressBar.Create(Self); FProg.Parent := Self;
  FProg.SetBounds(12, 446, 576, 16); FProg.Anchors := [akLeft, akRight, akBottom];
  FProg.Min := 0; FProg.Max := 1000; FProg.Position := 0;

  OnCloseQuery := @FCloseQuery;
end;

procedure TFCForm.FCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // don't tear the form down under a running scan; cancel first, close after
  if FRunning then
  begin
    if FThread <> nil then FThread.Cancel := True;
    FMainCancel := True;
    FSum.Caption := L('fc.cancelling', 'Cancelling...');
    CanClose := False;
  end
  else
    CanClose := True;
end;

procedure TFCForm.SetRunning(AOn: Boolean);
begin
  FRunning := AOn;
  FAlgo.Enabled := not AOn;
  FAllChk.Enabled := not AOn;
  FSelOnly.Enabled := (not AOn) and (FView <> nil) and (FView.SelCount > 0);
  if AOn then FBtn.Caption := L('fc.cancel', 'Cancel')
  else FBtn.Caption := L('fc.scan', 'Scan');
end;

procedure TFCForm.ShowHits(ACount: Integer; const AHits: TFCHits; AStart, ALen: Int64; ACancelled: Boolean);
var i: Integer; it: TListItem;
begin
  FHits := AHits;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i := 0 to ACount - 1 do
    begin
      it := FList.Items.Add;
      it.Caption := '0x' + IntToHex(AHits[i].Offset, 8);
      it.SubItems.Add(AHits[i].Algo);
      it.SubItems.Add(AHits[i].Name);
      it.SubItems.Add(IntToStr(AHits[i].Len));
    end;
  finally
    FList.Items.EndUpdate;
  end;
  FProg.Position := 0;
  SetRunning(False);
  if ACancelled then
    FSum.Caption := Format(L('fc.cancelled', 'Cancelled - %d hits so far.'), [ACount])
  else if ACount = 0 then
    FSum.Caption := Format(L('fc.none.range', 'No hits in 0x%s..0x%s.'),
      [IntToHex(AStart, 8), IntToHex(AStart + ALen, 8)])
  else
    FSum.Caption := Format(L('fc.hits', '%d hits.'), [ACount]);
end;

procedure TFCForm.MainProgress(APos, ATotal: Int64);
begin
  if ATotal > 0 then FProg.Position := Round(APos / ATotal * 1000);
  Application.ProcessMessages;         // keep UI alive on the fallback path
end;

procedure TFCForm.BeginScan;
var
  start, len: Int64;
  bf: string;
  n, i: Integer;
  hits: TFCHits;
  sel: TStringList;
begin
  if (FView = nil) or (FView.Source = nil) or (FView.DataSize <= 0) then Exit;

  if FSelOnly.Checked and (FView.SelCount > 0) then
  begin start := FView.SelStart; len := FView.SelCount; end
  else begin start := 0; len := FView.DataSize; end;

  // gather checked algorithms (empty => all, only if "All" ticked)
  sel := TStringList.Create;
  try
    if not FAllChk.Checked then
      for i := 0 to FAlgo.Items.Count - 1 do
        if FAlgo.Checked[i] then sel.Add(FAlgo.Items[i]);

    if (sel.Count = 0) and (not FAllChk.Checked) then
    begin
      FSum.Caption := L('fc.pickone', 'Check at least one algorithm (or tick All).');
      sel.Free; Exit;
    end;

    FSum.Caption := L('fc.scanning', 'Scanning...');
    SetRunning(True);

    bf := FView.BackingFileName;
    if (bf <> '') and (not FView.IsModified) then
    begin
      FThread := TScanThread.Create(Self, bf, sel, start, len);   // thread copies the list
      FThread.Start;
    end
    else
    begin
      FMainCancel := False;
      n := FindCryptoMulti(@FView.Source.ReadAt, start, len, hits, sel, @MainProgress, @FMainCancel);
      ShowHits(n, hits, start, len, FMainCancel);
    end;
  finally
    sel.Free;
  end;
end;

procedure TFCForm.DoScan(Sender: TObject);
begin
  if FRunning then
  begin
    if FThread <> nil then FThread.Cancel := True;
    FMainCancel := True;
    Exit;
  end;
  BeginScan;
end;

procedure TFCForm.DoDblClick(Sender: TObject);
var idx: Integer;
begin
  if FList.Selected = nil then Exit;
  idx := FList.Selected.Index;
  if (idx < 0) or (idx > High(FHits)) or (FView = nil) then Exit;
  FView.GotoOffset(FHits[idx].Offset);
  FView.SelectRange(FHits[idx].Offset, FHits[idx].Offset + FHits[idx].Len - 1);
  FView.SetFocus;
end;

procedure ShowFindCrypto(AOwner: TComponent; AView: THexView);
var f: TFCForm;
begin
  if (AView = nil) or (AView.Source = nil) or (AView.DataSize <= 0) then Exit;
  f := TFCForm.CreateNew(AOwner);
  f.FView := AView;
  if AOwner is TCustomForm then
  begin
    f.ShowInTaskBar := stNever; f.PopupMode := pmExplicit;
    f.PopupParent := TCustomForm(AOwner);
  end;
  f.FSelOnly.Enabled := AView.SelCount > 0;
  f.FSelOnly.Checked := AView.SelCount > 0;
  f.Show;
end;

end.
