unit uhexdev;

{$mode objfpc}{$H+}

// "Open device" picker: lists the physical drives and volumes the machine
// actually has, so nobody has to remember \\.\PhysicalDrive2.
//
// Windows: every drive is probed with a handle opened for NO access at all
// (dwDesiredAccess = 0). That needs no administrator rights and still answers
// the FILE_ANY_ACCESS control codes - geometry (size), storage descriptor
// (model, bus, removable) and the volume-to-disk mapping. Nothing is read from
// the media here; the list costs nothing and reveals nothing.
//
// Elsewhere the list comes from /sys/block (disks and their partitions).
//
// A disk image file can be picked too - it opens through the same raw source.

interface

uses
  ulang, Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, Dialogs,
  Clipbrd;

type
  TDevKind = (dkDisk, dkPart, dkVolume);

  TDevInfo = record
    Path:      string;      // what gets opened:  \\.\PhysicalDrive0 / \\.\C: / /dev/sda
    Display:   string;      // PhysicalDrive0, C:, sda1
    Kind:      TDevKind;
    Size:      Int64;       // 0 = unknown
    Descr:     string;      // model / label / file system
    Removable: Boolean;
  end;
  TDevList = array of TDevInfo;

function EnumDevices: TDevList;
function DevSizeStr(V: Int64): string;

// modal picker; returns True and the chosen path when the user confirms
function SelectDevice(AOwner: TComponent; out APath: string): Boolean;

// read-only report window with a Copy button (used for the write diagnostics)
procedure ShowReport(AOwner: TComponent; const ACaption, AText: string);

implementation

{$IFDEF WINDOWS}
uses Windows;

{$PACKRECORDS C}
const
  IOCTL_DISK_GET_LENGTH_INFO       = $0007405C;
  IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = $000700A0;
  IOCTL_STORAGE_QUERY_PROPERTY     = $002D1400;
  IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = $00560000;

type
  TStoragePropertyQuery = record
    PropertyId: DWORD;              // StorageDeviceProperty = 0
    QueryType: DWORD;               // PropertyStandardQuery = 0
    AdditionalParameters: array[0..3] of Byte;
  end;

  TStorageDeviceDescriptor = record
    Version: DWORD;
    Size: DWORD;
    DeviceType: Byte;
    DeviceTypeModifier: Byte;
    RemovableMedia: ByteBool;
    CommandQueueing: ByteBool;
    VendorIdOffset: DWORD;
    ProductIdOffset: DWORD;
    ProductRevisionOffset: DWORD;
    SerialNumberOffset: DWORD;
    BusType: DWORD;
    RawPropertiesLength: DWORD;
    RawDeviceProperties: array[0..0] of Byte;
  end;
  PStorageDeviceDescriptor = ^TStorageDeviceDescriptor;

  TDiskGeometry = record
    Cylinders: Int64;
    MediaType: DWORD;
    TracksPerCylinder: DWORD;
    SectorsPerTrack: DWORD;
    BytesPerSector: DWORD;
  end;

  TDiskGeometryEx = record
    Geometry: TDiskGeometry;
    DiskSize: Int64;
    Data: array[0..0] of Byte;
  end;

  TDiskExtent = record
    DiskNumber: DWORD;
    StartingOffset: Int64;
    ExtentLength: Int64;
  end;

  TVolumeDiskExtents = record
    NumberOfDiskExtents: DWORD;
    Extents: array[0..7] of TDiskExtent;
  end;
{$PACKRECORDS DEFAULT}

function BusTypeName(B: DWORD): string;
begin
  case B of
    1: Result := 'SCSI';   2: Result := 'ATAPI';  3: Result := 'ATA';
    4: Result := '1394';   5: Result := 'SSA';    6: Result := 'Fibre';
    7: Result := 'USB';    8: Result := 'RAID';   9: Result := 'iSCSI';
    $A: Result := 'SAS';   $B: Result := 'SATA';  $C: Result := 'SD';
    $D: Result := 'MMC';   $11: Result := 'NVMe';
  else Result := '';
  end;
end;

// a null-terminated ANSI string living at AOffset inside the descriptor buffer
function DescrStr(ABuf: PByte; AOffset: DWORD; ABufLen: DWORD): string;
begin
  Result := '';
  if (AOffset = 0) or (AOffset >= ABufLen) then Exit;
  Result := Trim(string(PAnsiChar(ABuf + AOffset)));
end;

// letters sitting on physical disk N, e.g. 'C:, D:'
function LettersOnDisk(ADisk: DWORD): string;
var
  drives: array[0..255] of Char;
  p: PChar;
  vol, letter: string;
  h: THandle;
  ext: TVolumeDiskExtents;
  br: DWORD;
  i: Integer;
begin
  Result := '';
  FillChar(drives, SizeOf(drives), 0);
  if GetLogicalDriveStrings(SizeOf(drives) - 1, drives) = 0 then Exit;
  p := @drives[0];
  while p^ <> #0 do
  begin
    letter := Copy(string(p), 1, 2);                 // 'C:'
    vol := '\\.\' + letter;
    h := CreateFile(PChar(vol), 0, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
           OPEN_EXISTING, 0, 0);
    if h <> INVALID_HANDLE_VALUE then
    try
      FillChar(ext, SizeOf(ext), 0);
      br := 0;
      if DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0,
           @ext, SizeOf(ext), br, nil) then
        for i := 0 to Integer(ext.NumberOfDiskExtents) - 1 do
          if (i <= High(ext.Extents)) and (ext.Extents[i].DiskNumber = ADisk) then
          begin
            if Result <> '' then Result := Result + ', ';
            Result := Result + letter;
            Break;
          end;
    finally
      CloseHandle(h);
    end;
    p := p + Length(string(p)) + 1;
  end;
end;

procedure AddPhysicalDrives(var L: TDevList);
var
  i, n: Integer;
  path, model, bus, letters: string;
  h: THandle;
  br: DWORD;
  len: Int64;
  gx: TDiskGeometryEx;
  q: TStoragePropertyQuery;
  buf: array[0..1023] of Byte;
  d: PStorageDeviceDescriptor;
begin
  for i := 0 to 31 do
  begin
    path := '\\.\PhysicalDrive' + IntToStr(i);
    // no access at all: enough for the informational IOCTLs, needs no rights
    h := CreateFile(PChar(path), 0, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
           OPEN_EXISTING, 0, 0);
    if h = INVALID_HANDLE_VALUE then Continue;       // no such drive
    try
      n := Length(L); SetLength(L, n + 1);
      L[n].Path := path;
      L[n].Display := 'PhysicalDrive' + IntToStr(i);
      L[n].Kind := dkDisk;
      L[n].Size := 0;
      L[n].Descr := '';
      L[n].Removable := False;

      len := 0; br := 0;
      if DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, nil, 0,
           @len, SizeOf(len), br, nil) then
        L[n].Size := len
      else
      begin
        FillChar(gx, SizeOf(gx), 0); br := 0;
        if DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, nil, 0,
             @gx, SizeOf(gx), br, nil) then
          L[n].Size := gx.DiskSize;
      end;

      model := ''; bus := '';
      FillChar(q, SizeOf(q), 0);
      FillChar(buf, SizeOf(buf), 0);
      br := 0;
      if DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, @q, SizeOf(q),
           @buf, SizeOf(buf), br, nil) then
      begin
        d := PStorageDeviceDescriptor(@buf[0]);
        model := Trim(DescrStr(@buf[0], d^.VendorIdOffset, br) + ' ' +
                      DescrStr(@buf[0], d^.ProductIdOffset, br));
        bus := BusTypeName(d^.BusType);
        L[n].Removable := d^.RemovableMedia;
      end;

      L[n].Descr := model;
      if bus <> '' then
        if L[n].Descr <> '' then L[n].Descr := L[n].Descr + '  [' + bus + ']'
        else L[n].Descr := '[' + bus + ']';
    finally
      CloseHandle(h);
    end;

    letters := LettersOnDisk(i);
    if letters <> '' then
      L[High(L)].Descr := Trim(L[High(L)].Descr + '  -> ' + letters);
  end;
end;

procedure AddVolumes(var L: TDevList);
var
  drives: array[0..255] of Char;
  p: PChar;
  root, letter, lbl, fs: string;
  nameBuf, fsBuf: array[0..MAX_PATH] of Char;
  serial, maxComp, flags: DWORD;
  total, freeAvail, freeTotal: Int64;
  n: Integer;
  t: UINT;
begin
  FillChar(drives, SizeOf(drives), 0);
  if GetLogicalDriveStrings(SizeOf(drives) - 1, drives) = 0 then Exit;
  p := @drives[0];
  while p^ <> #0 do
  begin
    root := string(p);                                // 'C:\'
    letter := Copy(root, 1, 2);
    t := GetDriveType(PChar(root));
    if t in [DRIVE_FIXED, DRIVE_REMOVABLE, DRIVE_RAMDISK] then
    begin
      lbl := ''; fs := '';
      FillChar(nameBuf, SizeOf(nameBuf), 0);
      FillChar(fsBuf, SizeOf(fsBuf), 0);
      if GetVolumeInformation(PChar(root), nameBuf, MAX_PATH, @serial,
           maxComp, flags, fsBuf, MAX_PATH) then
      begin
        lbl := Trim(string(nameBuf));
        fs := Trim(string(fsBuf));
      end;
      total := 0;
      if not GetDiskFreeSpaceEx(PChar(root), @freeAvail, @total, @freeTotal) then
        total := 0;

      n := Length(L); SetLength(L, n + 1);
      L[n].Path := '\\.\' + letter;
      L[n].Display := letter;
      L[n].Kind := dkVolume;
      L[n].Size := total;
      L[n].Removable := (t = DRIVE_REMOVABLE);
      L[n].Descr := Trim(lbl + ' ' + fs);
    end;
    p := p + Length(string(p)) + 1;
  end;
end;

function EnumDevices: TDevList;
begin
  Result := nil;
  try AddPhysicalDrives(Result); except end;
  try AddVolumes(Result); except end;
end;

{$ELSE}

// ---- POSIX: /sys/block tells us everything without touching the media ------

function ReadSysStr(const AFile: string): string;
var f: TextFile;
begin
  Result := '';
  if not FileExists(AFile) then Exit;
  try
    AssignFile(f, AFile); Reset(f);
    try if not Eof(f) then ReadLn(f, Result); finally CloseFile(f); end;
  except
    Result := '';
  end;
  Result := Trim(Result);
end;

function ReadSysInt(const AFile: string): Int64;
begin
  Result := StrToInt64Def(ReadSysStr(AFile), 0);
end;

procedure AddOne(var L: TDevList; const AName, ASysDir: string;
  AKind: TDevKind; const ADescr: string);
var n: Integer;
begin
  n := Length(L); SetLength(L, n + 1);
  L[n].Path := '/dev/' + AName;
  L[n].Display := AName;
  L[n].Kind := AKind;
  L[n].Size := ReadSysInt(ASysDir + '/size') * 512;   // sysfs counts 512B units
  L[n].Removable := ReadSysInt(ASysDir + '/removable') = 1;
  L[n].Descr := ADescr;
end;

// /sys/block hands them over in directory order; sort so the list is stable
procedure SortByName(var L: TDevList);
var i, j: Integer; t: TDevInfo;
begin
  for i := 1 to High(L) do
  begin
    t := L[i]; j := i - 1;
    while (j >= 0) and (CompareStr(L[j].Display, t.Display) > 0) do
    begin
      L[j + 1] := L[j];
      Dec(j);
    end;
    L[j + 1] := t;
  end;
end;

function EnumDevices: TDevList;
var
  sr, sp: TSearchRec;
  base, dir, descr, vendor, model: string;
begin
  Result := nil;
  base := '/sys/block/';
  if FindFirst(base + '*', faAnyFile or faDirectory, sr) <> 0 then Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      // loop/ram devices are noise in a device picker
      if (Pos('loop', sr.Name) = 1) or (Pos('ram', sr.Name) = 1) then Continue;
      dir := base + sr.Name;
      if ReadSysInt(dir + '/size') <= 0 then Continue;

      vendor := ReadSysStr(dir + '/device/vendor');
      model := ReadSysStr(dir + '/device/model');
      descr := Trim(vendor + ' ' + model);
      if ReadSysInt(dir + '/ro') = 1 then descr := Trim(descr + ' (ro)');
      AddOne(Result, sr.Name, dir, dkDisk, descr);

      // partitions live as sub-directories carrying a "partition" file
      if FindFirst(dir + '/' + sr.Name + '*', faAnyFile or faDirectory, sp) = 0 then
      try
        repeat
          if (sp.Name = '.') or (sp.Name = '..') then Continue;
          if not FileExists(dir + '/' + sp.Name + '/partition') then Continue;
          AddOne(Result, sp.Name, dir + '/' + sp.Name, dkPart, '');
        until FindNext(sp) <> 0;
      finally
        FindClose(sp);
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  SortByName(Result);
end;

{$ENDIF}

function DevSizeStr(V: Int64): string;
begin
  if V <= 0 then Exit('');
  if V >= Int64(1024)*1024*1024*1024 then
    Result := Format('%.2f TB', [V / (Int64(1024)*1024*1024*1024)])
  else if V >= 1024*1024*1024 then
    Result := Format('%.1f GB', [V / (1024*1024*1024)])
  else if V >= 1024*1024 then
    Result := Format('%.1f MB', [V / (1024*1024)])
  else
    Result := Format('%d B', [V]);
end;

{ ---- picker dialog --------------------------------------------------------- }

type
  TDevForm = class(TForm)
  private
    FList: TListView;
    FPath: TEdit;
    FDevs: TDevList;
    procedure DoRefresh(Sender: TObject);
    procedure DoSelect(Sender: TObject);
    procedure DoDblClick(Sender: TObject);
    procedure DoPickFile(Sender: TObject);
    procedure DoOk(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure Fill;
  end;

constructor TDevForm.CreateNew(AOwner: TComponent; Num: Integer);
var c: TListColumn; lbl: TLabel;
begin
  inherited CreateNew(AOwner, Num);
  Caption := L('dev.pick.title', 'Избор на устройство');
  Position := poScreenCenter;
  BorderStyle := bsSizeable;
  ClientWidth := 640;
  ClientHeight := 420;

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(12, 10, 620, 16);
  lbl.Caption := L('dev.pick.hint',
    'Избери устройство от списъка или напиши път ръчно.');

  FList := TListView.Create(Self); FList.Parent := Self;
  FList.SetBounds(12, 32, 616, 288);
  FList.Anchors := [akLeft, akTop, akRight, akBottom];
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.HideSelection := False;
  FList.OnSelectItem := nil;
  FList.OnClick := @DoSelect;
  FList.OnDblClick := @DoDblClick;
  c := FList.Columns.Add; c.Caption := L('dev.col.dev', 'Устройство'); c.Width := 150;
  c := FList.Columns.Add; c.Caption := L('dev.col.kind', 'Тип');        c.Width := 90;
  c := FList.Columns.Add; c.Caption := L('dev.col.size', 'Размер');     c.Width := 100;
  c := FList.Columns.Add; c.Caption := L('dev.col.descr', 'Описание');  c.Width := 260;

  lbl := TLabel.Create(Self); lbl.Parent := Self;
  lbl.SetBounds(12, 332, 40, 16); lbl.Anchors := [akLeft, akBottom];
  lbl.Caption := L('dev.pick.path', 'Път:');

  FPath := TEdit.Create(Self); FPath.Parent := Self;
  FPath.SetBounds(56, 328, 460, 24);
  FPath.Anchors := [akLeft, akRight, akBottom];

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(524, 327, 104, 26);
    Anchors := [akRight, akBottom];
    Caption := L('dev.pick.file', 'Файл...'); OnClick := @DoPickFile;
  end;

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(12, 372, 120, 30);
    Anchors := [akLeft, akBottom];
    Caption := L('dev.pick.refresh', 'Обнови'); OnClick := @DoRefresh;
  end;

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(396, 372, 110, 30);
    Anchors := [akRight, akBottom];
    Caption := L('dev.pick.ok', 'Отвори'); OnClick := @DoOk; Default := True;
  end;

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(518, 372, 110, 30);
    Anchors := [akRight, akBottom];
    Caption := L('dev.pick.cancel', 'Отказ');
    ModalResult := mrCancel; Cancel := True;
  end;
end;

procedure TDevForm.Fill;
var i: Integer; it: TListItem; k: string;
begin
  FDevs := EnumDevices;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i := 0 to High(FDevs) do
    begin
      it := FList.Items.Add;
      it.Caption := FDevs[i].Display;
      case FDevs[i].Kind of
        dkDisk:   k := L('dev.kind.disk', 'диск');
        dkPart:   k := L('dev.kind.part', 'дял');
      else        k := L('dev.kind.vol', 'том');
      end;
      if FDevs[i].Removable then k := k + L('dev.kind.rem', ', сменяем');
      it.SubItems.Add(k);
      it.SubItems.Add(DevSizeStr(FDevs[i].Size));
      it.SubItems.Add(FDevs[i].Descr);
      it.Data := Pointer(PtrInt(i));
    end;
  finally
    FList.Items.EndUpdate;
  end;
  if FList.Items.Count = 0 then
    FPath.Text := ''
  else
  begin
    FList.Items[0].Selected := True;
    DoSelect(nil);
  end;
end;

procedure TDevForm.DoRefresh(Sender: TObject);
begin
  Fill;
end;

procedure TDevForm.DoSelect(Sender: TObject);
var i: Integer;
begin
  if FList.Selected = nil then Exit;
  i := PtrInt(FList.Selected.Data);
  if (i >= 0) and (i <= High(FDevs)) then FPath.Text := FDevs[i].Path;
end;

procedure TDevForm.DoDblClick(Sender: TObject);
begin
  if FList.Selected = nil then Exit;
  DoSelect(Sender);
  DoOk(Sender);
end;

procedure TDevForm.DoPickFile(Sender: TObject);
var dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := L('dev.pick.filetitle', 'Избери образ на диск');
    if dlg.Execute then FPath.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

procedure TDevForm.DoOk(Sender: TObject);
begin
  if Trim(FPath.Text) = '' then Exit;
  ModalResult := mrOk;
end;

{ ---- plain report window -------------------------------------------------- }

type
  TReportForm = class(TForm)
  private
    FMemo: TMemo;
    procedure DoCopy(Sender: TObject);
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
  end;

constructor TReportForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  Position := poScreenCenter;
  BorderStyle := bsSizeable;
  ClientWidth := 640;
  ClientHeight := 440;

  FMemo := TMemo.Create(Self); FMemo.Parent := Self;
  FMemo.SetBounds(12, 12, 616, 380);
  FMemo.Anchors := [akLeft, akTop, akRight, akBottom];
  FMemo.ReadOnly := True;
  FMemo.ScrollBars := ssAutoBoth;
  FMemo.WordWrap := False;
  FMemo.Font.Name := 'Courier New';
  FMemo.Font.Size := 9;

  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(12, 402, 140, 28);
    Anchors := [akLeft, akBottom];
    Caption := L('rep.copy', 'Копирай'); OnClick := @DoCopy;
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self; SetBounds(518, 402, 110, 28);
    Anchors := [akRight, akBottom];
    Caption := L('rep.close', 'Затвори');
    ModalResult := mrOk; Default := True; Cancel := True;
  end;
end;

procedure TReportForm.DoCopy(Sender: TObject);
begin
  Clipboard.AsText := FMemo.Lines.Text;
end;

procedure ShowReport(AOwner: TComponent; const ACaption, AText: string);
var f: TReportForm;
begin
  f := TReportForm.CreateNew(AOwner);
  try
    f.Caption := ACaption;
    f.FMemo.Lines.Text := AText;
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

function SelectDevice(AOwner: TComponent; out APath: string): Boolean;
var f: TDevForm;
begin
  Result := False;
  APath := '';
  f := TDevForm.CreateNew(AOwner);
  try
    if AOwner is TCustomForm then
    begin
      f.ShowInTaskBar := stNever;
      f.PopupMode := pmExplicit;
      f.PopupParent := TCustomForm(AOwner);
    end;
    f.Fill;
    if f.ShowModal = mrOk then
    begin
      APath := Trim(f.FPath.Text);
      Result := APath <> '';
    end;
  finally
    f.Free;
  end;
end;

end.
