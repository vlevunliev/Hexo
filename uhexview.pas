{
  uHexView - a from-scratch, Int64-native, virtual hex viewer control.

  Design goals (deliberately NOT built on TCustomGrid):
    * Int64 addressing everywhere -> no 2 GB ceiling (bounded only by the source).
    * Virtual rendering: only the visible rows are read and drawn; nothing is
      allocated per row, so multi-GB sources cost nothing extra.
    * Pluggable byte sources (in-memory / on-demand file / Win32 mmap) so the
      whole file need not sit in RAM.
    * Custom Int64 scroll model mapped onto the 32-bit platform scrollbar.
    * UTF-8-aware character pane (multi-byte glyph on the lead cell, Latin-1
      fallback for invalid bytes) and table-based hex conversion.

  v1 is read-only. Editing (piece-table overlay) and raw-device sources are the
  next stage and sit on top of this core without touching the renderer.
}
unit uHexView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Controls, Graphics, Forms, StdCtrls, LCLType, LMessages,
  Clipbrd, {$IFDEF WINDOWS}Windows,{$ENDIF} Types;

type
  TFileOfs = Int64;

  { abstract byte source ------------------------------------------------------ }

  TByteSource = class
  public
    function Size: TFileOfs; virtual; abstract;
    // read up to ALen bytes at APos into ABuf; returns bytes actually read
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
      virtual; abstract;
    // sources that can be written back to override these; the default source
    // is read-only, so nothing writes anywhere unless it opted in
    function CanWrite: Boolean; virtual;
    // write ALen bytes at APos; returns bytes written, raises on device error
    function WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer; virtual;
    procedure Flush; virtual;
    // read for verification purposes: must defeat every cache between us and
    // the platter. The default is a plain read; sources that can do better
    // (a raw device: a brand-new handle) override it.
    function VerifyReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; virtual;
  end;

  // a contiguous run of edited bytes, in final-image coordinates
  TModRange = record
    Start, Len: TFileOfs;
  end;
  TModRanges = array of TModRange;

  { raised when the device itself could not be opened; Code is the OS error,
    5 (access denied) meaning "not running as administrator" }
  EHexOpen = class(Exception)
  public
    Code: LongWord;
    constructor CreateFor(const ADevice: string; ACode: LongWord);
  end;

  { raised when a write reported success but reading the bytes back gives
    something else - the case where Windows quietly drops a raw-device write }
  EHexVerify = class(Exception)
  public
    Offset: TFileOfs;
    constructor CreateAt(AOffset: TFileOfs);
  end;

  { whole buffer held in memory (small files / clipboard data) }
  TMemByteSource = class(TByteSource)
  private
    FData: array of Byte;
  public
    constructor Create(const AData; ALen: Integer);
    constructor CreateFromFile(const AFileName: string);
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
  end;

  { on-demand file reading via TFileStream seek+read - no whole-file-in-RAM,
    cross-platform, the safe default workhorse for large files }
  TFileByteSource = class(TByteSource)
  private
    FStream: TFileStream;
    FSize: TFileOfs;
    FFileName: string;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    property FileName: string read FFileName;
  end;

  { raw physical drive / volume access (e.g. \\.\PhysicalDrive0, \\.\C:).
    Windows: CreateFile + IOCTL length + sector-aligned reads.
    Other OS: falls back to reading the path as a block device file. }
  TRawDeviceByteSource = class(TByteSource)
  private
    {$IFDEF WINDOWS}
    FHandle: THandle;
    {$ELSE}
    FStream: TFileStream;
    {$ENDIF}
    {$IFDEF WINDOWS}
    FVolLocks: array of THandle;   // volumes held open+locked while writing
    FMem: Pointer;                 // sector-aligned buffer (FILE_FLAG_NO_BUFFERING)
    FMemLen: Integer;
    {$ENDIF}
    FSize: TFileOfs;
    FSector: Integer;
    FWritable: Boolean;
    FLockVols: Boolean;          // may we lock/dismount the volumes?
    FExclusive: Boolean;
    FDevice: string;
    FLockLog: string;            // what happened to each volume at open time
    FVolAreas: array of TModRange;   // disk areas occupied by mounted volumes
    FAllDismounted: Boolean;         // every volume of this device let go
    FBuf: array of Byte;
    {$IFDEF WINDOWS}
    procedure QuerySectorSize;
    procedure LockVolumes;
    procedure UnlockVolumes;
    {$ENDIF}
    function WorkBuf(ALen: Integer): PByte;
  public
    // AWritable opens the device for writing too; it fails loudly (raises) when
    // the caller lacks the rights, rather than silently degrading to read-only
    // ALockVolumes = False opens the device without locking or dismounting the
    // volumes on it - useful when that very cycle is what corrupts the result
    constructor Create(const ADevice: string; AWritable: Boolean = False;
      ALockVolumes: Boolean = True);
    destructor Destroy; override;
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    function CanWrite: Boolean; override;
    // sector-aligned read-modify-write; never changes the device length
    function WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer; override;
    procedure Flush; override;
    // reads through a handle opened just for this read, so neither Windows nor
    // the storage stack can answer from something it cached a moment ago
    function VerifyReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    property Device: string read FDevice;
    property SectorSize: Integer read FSector;
    // True when the volumes living on this device were locked for us
    property Exclusive: Boolean read FExclusive;
    // per-volume outcome of the locking attempt, one line each
    property LockLog: string read FLockLog;
    // Ask Windows to stop the device, exactly like "Safely remove hardware".
    // On a USB stick this is what makes the controller flush its cache for
    // good. Returns a human-readable outcome.
    function EjectDevice: string;
    // True when AOfs falls inside a volume that Windows has mounted on this
    // device - the sectors a file-system driver believes it owns
    function InMountedVolume(AOfs: TFileOfs): Boolean;
    // False when a volume of this device stayed mounted: writes inside it can
    // be undone by its file-system driver
    property VolumesDismounted: Boolean read FAllDismounted;
    // Step-by-step probe of the write path at ATestOffset. It flips one byte
    // and puts it straight back, reporting every call and error code, so a
    // silent failure can be pinned on a specific step.
    function Diagnose(ATestOffset: TFileOfs): string;
  end;

  { non-destructive piece-table editing layer over any backing source --------- }

  TPieceKind = (pkOrig, pkAdd);

  TPiece = record
    Kind: TPieceKind;
    Start: TFileOfs;      // offset into backing (pkOrig) or add buffer (pkAdd)
    Len: TFileOfs;
  end;
  TPieceArray = array of TPiece;

  TUndoState = record
    Pieces: TPieceArray;
    Sz: TFileOfs;
  end;

  TEditByteSource = class(TByteSource)
  private
    FBack: TByteSource;
    FOwnsBack: Boolean;
    FAdd: TMemoryStream;
    FPieces: TPieceArray;
    FSize: TFileOfs;
    FModified: Boolean;
    FFixedLength: Boolean;
    FUndo: array of TUndoState;
    FRedo: array of TUndoState;
    procedure RecomputeSize;
    function PieceIndexAt(APos: TFileOfs): Integer;
    procedure SplitAt(APos: TFileOfs);
    function ClonePieces: TPieceArray;
    procedure PushUndo;
    function AppendToAdd(const AData; ALen: Integer): TFileOfs;
    procedure DoInsert(APos: TFileOfs; AAddStart, ALen: TFileOfs);
    procedure DoDelete(APos, ALen: TFileOfs);
    procedure Restore(const AState: TUndoState);
  public
    constructor Create(ABack: TByteSource; AOwnsBack: Boolean);
    destructor Destroy; override;
    function Size: TFileOfs; override;
    function ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer; override;
    procedure Overwrite(APos: TFileOfs; const AData; ALen: Integer);
    procedure InsertData(APos: TFileOfs; const AData; ALen: Integer);
    procedure DeleteRange(APos, ALen: TFileOfs);
    function ByteModified(APos: TFileOfs): Boolean;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    procedure Undo;
    procedure Redo;
    procedure SaveToStream(AStream: TStream);
    procedure SaveToFile(const AFileName: string);
    procedure Rebase(ANewBack: TByteSource; AOwnsBack: Boolean);
    procedure CloseBacking;
    function BackingFileName: string;
    // the edited runs, in final-image coordinates (adjacent ones merged)
    function ModifiedRanges: TModRanges;
    function ModifiedByteCount: TFileOfs;
    function CanCommit: Boolean;
    // write the edited runs back into the backing source in place, then start
    // over from a clean slate (undo history is dropped - it is on the disk now)
    procedure CommitToBacking;
    // when set, the image can never change length: insert and delete are
    // refused and overwrites are clipped to the existing end. Set it for any
    // backing that cannot grow - a raw device, most of all.
    property FixedLength: Boolean read FFixedLength write FFixedLength;
    property Modified: Boolean read FModified write FModified;
    property Backing: TByteSource read FBack;
  end;

  { the view ------------------------------------------------------------------ }

  THexField = (hfNone, hfHex, hfChar);

  // block operations applied to the current selection (undoable)
  THexOp = (hopNot, hopAnd, hopOr, hopXor, hopAdd, hopSub, hopMul, hopDiv,
    hopMod, hopShl, hopShr, hopRol, hopRor, hopNeg, hopFlip, hopUpper,
    hopLower, hopInvCase, hopFill);

  TByteFormatEvent = procedure(Sender: TObject; APos: TFileOfs; AByte: Byte;
    var AForeColor, ABackColor: TColor) of object;

  THexView = class(TCustomControl)
  private
    FSource: TByteSource;
    FEdit: TEditByteSource;        // non-nil when FSource is editable
    FOwnsSource: Boolean;
    FInsertMode: Boolean;          // insert vs overwrite
    FLowNibble: Boolean;           // hex typing: editing low nibble of current byte
    FBytesPerRow: Integer;
    FGroupSize: Integer;            // blank column every FGroupSize bytes
    FTopRow: TFileOfs;
    FCurPos: TFileOfs;
    FSelAnchor: TFileOfs;
    FHasSel: Boolean;
    FActiveField: THexField;
    FUtf8CharPane: Boolean;
    FHexCopySpaces: Boolean;
    FLastPattern: TBytes;
    FLastCaseIns: Boolean;

    FScrollBar: TScrollBar;
    FUpdatingScroll: Boolean;

    FCharW, FRowH, FTextTop: Integer;
    FOffsetChars: Integer;
    FHexX0, FCharX0, FViewW: Integer;

    FColOffsetBk, FColOffsetTx, FColHexBk, FColHexTx, FColCharBk, FColCharTx,
      FColSelBk, FColSelTx, FColRule, FColModTx: TColor;

    FOnByteFormat: TByteFormatEvent;
    FOnSelChange: TNotifyEvent;
    FOnEditChange: TNotifyEvent;

    procedure SetSource(AValue: TByteSource);
    procedure SetBytesPerRow(AValue: Integer);
    procedure SetGroupSize(AValue: Integer);
    procedure SetUtf8CharPane(AValue: Boolean);
    function GetSize: TFileOfs;

    function TotalRows: TFileOfs;
    function VisibleRows: Integer;
    function MaxTopRow: TFileOfs;
    procedure ClampTop;
    procedure UpdateMetrics;
    procedure UpdateScrollBar;
    procedure ScrollBarScroll(Sender: TObject; ScrollCode: TScrollCode;
      var ScrollPos: Integer);
    function HexByteX(AIndex: Integer): Integer;
    function CharByteX(AIndex: Integer): Integer;
    procedure PosToField(X, Y: Integer; out APos: TFileOfs; out AField: THexField);
    function ReadRow(ARow: TFileOfs; var ABuf; AMax: Integer): Integer;
    function CellGlyph(const AWin: array of Byte; AWinLen, AIdx: Integer): string;
    procedure DoSelChange;
    procedure DoEditChange;
    procedure AfterEdit;
    procedure EditHexNibble(ADigit: Integer);
    procedure EditCharByte(AByte: Byte);
    procedure DeleteAtCursor(ABackspace: Boolean);
    procedure SetInsertMode(AValue: Boolean);
  protected
    procedure InitializeWnd; override;
    procedure Paint; override;
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: char); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure LoadFromFile(const AFileName: string; InMemory: Boolean = False);
    procedure SetByteSource(ASource: TByteSource; AOwns: Boolean);
    procedure CloseSource;

    // editing (active only when the current source is a TEditByteSource)
    procedure OpenEditable(const AFileName: string; InMemory: Boolean = False);
    function IsEditable: Boolean;
    function IsModified: Boolean;
    function BackingFileName: string;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    procedure Undo;
    procedure Redo;
    procedure DeleteSelection;
    procedure OverwriteSelection(const AData: TBytes);
    procedure ApplySelectionOp(AOp: THexOp; AOperand: Byte);
    procedure SaveToFile(const AFileName: string);

    // in-place write-back into the backing source (raw device editing)
    procedure OpenDevice(const ADevice: string; AWritable: Boolean;
      ALockVolumes: Boolean = True);
    function IsFixedLength: Boolean;
    function CanCommit: Boolean;          // editable AND backing accepts writes
    function ModifiedRanges: TModRanges;
    function ModifiedByteCount: TFileOfs;
    procedure CommitToBacking;

    property EditSource: TEditByteSource read FEdit;
    property Source: TByteSource read FSource;

    procedure ScrollToRow(ARow: TFileOfs);
    procedure EnsureVisible(APos: TFileOfs);
    procedure SetCursorPos(APos: TFileOfs; AExtendSel: Boolean);

    property DataSize: TFileOfs read GetSize;
    property CursorPos: TFileOfs read FCurPos;
    function SelStart: TFileOfs;
    function SelEnd: TFileOfs;      // inclusive; = SelStart-1 when empty
    function SelCount: TFileOfs;
    procedure SelectRange(AStart, AEnd: TFileOfs);

    // streaming Int64 search
    function FindBytes(const APattern; APatLen: Integer; AStart: TFileOfs;
      ACaseInsensitive: Boolean): TFileOfs;
    function FindFirst(const APattern; APatLen: Integer;
      ACaseInsensitive: Boolean): Boolean;
    function FindNext: Boolean;
    class function ParseHexPattern(const S: string; out ABytes: TBytes): Boolean;
    procedure GotoOffset(APos: TFileOfs);

    // clipboard / export - operate on the current selection
    function ReadSelection: TBytes;
    procedure CopySelectionHex;
    procedure CopySelectionText;
    procedure ExportSelectionBin(const AFile: string);
    procedure ExportSelectionC(const AFile, AVarName: string);
    procedure ExportSelectionPascal(const AFile, AVarName: string);
  published
    property BytesPerRow: Integer read FBytesPerRow write SetBytesPerRow
      default 16;
    property GroupSize: Integer read FGroupSize write SetGroupSize default 8;
    property Utf8CharPane: Boolean read FUtf8CharPane write SetUtf8CharPane
      default True;
    property HexCopySpaces: Boolean read FHexCopySpaces write FHexCopySpaces
      default True;
    property InsertMode: Boolean read FInsertMode write SetInsertMode default False;
    property OnByteFormat: TByteFormatEvent read FOnByteFormat write FOnByteFormat;
    property OnSelChange: TNotifyEvent read FOnSelChange write FOnSelChange;
    property OnEditChange: TNotifyEvent read FOnEditChange write FOnEditChange;

    property Align;
    property Anchors;
    property BorderSpacing;
    property Color;
    property Font;
    property PopupMenu;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property OnClick;
    property OnKeyPress;
  end;

implementation

const
  HEXDIG: array[0..15] of Char = '0123456789ABCDEF';

var
  // byte -> two uppercase hex chars, built once
  HexPair: array[Byte] of packed array[0..1] of Char;

procedure InitHexPair;
var b: Integer;
begin
  for b := 0 to 255 do
  begin
    HexPair[b][0] := HEXDIG[b shr 4];
    HexPair[b][1] := HEXDIG[b and 15];
  end;
end;

constructor EHexOpen.CreateFor(const ADevice: string; ACode: LongWord);
begin
  inherited CreateFmt('Cannot open %s (error %d)', [ADevice, ACode]);
  Code := ACode;
end;

constructor EHexVerify.CreateAt(AOffset: TFileOfs);
begin
  inherited CreateFmt('Write not confirmed at offset 0x%s - the device read ' +
    'back the old bytes.', [IntToHex(AOffset, 8)]);
  Offset := AOffset;
end;

{ TByteSource - read-only by default ----------------------------------------- }

function TByteSource.CanWrite: Boolean;
begin
  Result := False;
end;

function TByteSource.WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer;
begin
  Result := 0;   // a source that cannot write simply writes nothing
end;

procedure TByteSource.Flush;
begin
end;

function TByteSource.VerifyReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := ReadAt(APos, ABuf, ALen);
end;

{ TMemByteSource ------------------------------------------------------------- }

constructor TMemByteSource.Create(const AData; ALen: Integer);
begin
  inherited Create;
  SetLength(FData, ALen);
  if ALen > 0 then
    System.Move(AData, FData[0], ALen);
end;

constructor TMemByteSource.CreateFromFile(const AFileName: string);
var fs: TFileStream;
begin
  inherited Create;
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(FData, fs.Size);
    if Length(FData) > 0 then
      fs.ReadBuffer(FData[0], Length(FData));
  finally
    fs.Free;
  end;
end;

function TMemByteSource.Size: TFileOfs;
begin
  Result := Length(FData);
end;

function TMemByteSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := 0;
  if (APos < 0) or (APos >= Length(FData)) or (ALen <= 0) then Exit;
  if APos + ALen > Length(FData) then
    ALen := Length(FData) - APos;
  System.Move(FData[APos], ABuf, ALen);
  Result := ALen;
end;

{ TFileByteSource ------------------------------------------------------------ }

constructor TFileByteSource.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
  FStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  FSize := FStream.Size;
end;

destructor TFileByteSource.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

function TFileByteSource.Size: TFileOfs;
begin
  Result := FSize;
end;

function TFileByteSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
begin
  Result := 0;
  if (APos < 0) or (APos >= FSize) or (ALen <= 0) then Exit;
  if APos + ALen > FSize then
    ALen := FSize - APos;
  FStream.Position := APos;
  Result := FStream.Read(ABuf, ALen);
end;

{ TRawDeviceByteSource ------------------------------------------------------- }

{$IFDEF WINDOWS}
const
  IOCTL_DISK_GET_LENGTH_INFO       = $0007405C;
  IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = $000700A0;
  IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = $00560000;
  // exclusive access to a volume, and permission to touch every sector of it
  FSCTL_LOCK_VOLUME             = $00090018;
  FSCTL_UNLOCK_VOLUME           = $0009001C;
  FSCTL_DISMOUNT_VOLUME         = $00090020;
  FSCTL_ALLOW_EXTENDED_DASD_IO  = $000900CC;
  // what "Safely remove hardware" does: stop the unit so the drive's own
  // controller is forced to commit everything it is still holding in RAM
  IOCTL_STORAGE_MEDIA_REMOVAL   = $002D4804;
  IOCTL_STORAGE_EJECT_MEDIA     = $002D4808;

{$PACKRECORDS C}
type
  TDiskGeometryRec = record
    Cylinders: Int64;
    MediaType: DWORD;
    TracksPerCylinder: DWORD;
    SectorsPerTrack: DWORD;
    BytesPerSector: DWORD;
  end;
  TDiskGeometryExRec = record
    Geometry: TDiskGeometryRec;
    DiskSize: Int64;
    Data: array[0..0] of Byte;
  end;
  TDiskExtentRec = record
    DiskNumber: DWORD;
    StartingOffset: Int64;
    ExtentLength: Int64;
  end;
  TVolumeDiskExtentsRec = record
    NumberOfDiskExtents: DWORD;
    Extents: array[0..7] of TDiskExtentRec;
  end;
{$PACKRECORDS DEFAULT}

// FPC's Windows unit exposes SetFilePointer (32-bit) but not the Ex variant;
// declare it ourselves (available on every Windows since XP)
function SetFilePointerEx(hFile: THandle; liDistanceToMove: Int64;
  lpNewFilePointer: PInt64; dwMoveMethod: DWORD): BOOL; stdcall;
  external 'kernel32' name 'SetFilePointerEx';
{$ENDIF}

{$IFDEF WINDOWS}
// The real sector size. Hard-coding 512 breaks 4Kn drives and many USB sticks:
// with FILE_FLAG_NO_BUFFERING every offset and length must be a multiple of it.
procedure TRawDeviceByteSource.QuerySectorSize;
var gx: TDiskGeometryExRec; br: DWORD;
begin
  FillChar(gx, SizeOf(gx), 0); br := 0;
  if DeviceIoControl(FHandle, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, nil, 0,
       @gx, SizeOf(gx), br, nil) then
    if (gx.Geometry.BytesPerSector >= 512) and
       (gx.Geometry.BytesPerSector <= 65536) then
      FSector := gx.Geometry.BytesPerSector;
end;

// Windows refuses (or silently drops) writes to sectors owned by a mounted
// volume. Take every volume that lives on this device, lock it, and ask for
// extended DASD I/O so the whole volume - not just its free space - is ours.
// Best effort: a volume in use stays unlocked and only that area may fail.
procedure TRawDeviceByteSource.LockVolumes;
var
  drives: array[0..255] of Char;
  p: PChar;
  letter, vol: string;
  h: THandle;
  ext: TVolumeDiskExtentsRec;
  br: DWORD;
  i, n: Integer;
  wantDisk: Integer;
  mine, locked: Boolean;
  err: DWORD;
begin
  FExclusive := False;
  FLockLog := '';
  FAllDismounted := True;
  // \\.\X: - lock that one volume;  \\.\PhysicalDriveN - lock all of its volumes
  wantDisk := -1;
  if Pos('PHYSICALDRIVE', UpperCase(FDevice)) > 0 then
    wantDisk := StrToIntDef(Copy(UpperCase(FDevice),
      Pos('PHYSICALDRIVE', UpperCase(FDevice)) + 13, 8), -1);

  FillChar(drives, SizeOf(drives), 0);
  if GetLogicalDriveStrings(SizeOf(drives) - 1, drives) = 0 then
  begin
    FLockLog := '  (no logical drives enumerated)' + LineEnding;
    Exit;
  end;
  p := @drives[0];
  while p^ <> #0 do
  begin
    letter := Copy(string(p), 1, 2);
    vol := '\\.\' + letter;
    mine := False;
    if wantDisk < 0 then
      mine := SameText(vol, FDevice)
    else
    begin
      h := CreateFile(PChar(vol), 0, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
             OPEN_EXISTING, 0, 0);
      if h <> INVALID_HANDLE_VALUE then
      try
        FillChar(ext, SizeOf(ext), 0); br := 0;
        if DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0,
             @ext, SizeOf(ext), br, nil) then
          for i := 0 to Integer(ext.NumberOfDiskExtents) - 1 do
            if (i <= High(ext.Extents)) and
               (Integer(ext.Extents[i].DiskNumber) = wantDisk) then
            begin
              mine := True;
              // remember which part of the disk this volume owns
              n := Length(FVolAreas); SetLength(FVolAreas, n + 1);
              FVolAreas[n].Start := ext.Extents[i].StartingOffset;
              FVolAreas[n].Len := ext.Extents[i].ExtentLength;
              FLockLog := FLockLog + Format(
                '  %s: occupies 0x%s .. 0x%s of this disk',
                [letter, IntToHex(ext.Extents[i].StartingOffset, 8),
                 IntToHex(ext.Extents[i].StartingOffset +
                          ext.Extents[i].ExtentLength - 1, 8)]) + LineEnding;
            end;
      finally
        CloseHandle(h);
      end;
    end;

    if mine and not FLockVols then
      FLockLog := FLockLog + Format(
        '  %s: left mounted (locking not requested)', [letter]) + LineEnding;

    if mine and FLockVols then
    begin
      h := CreateFile(PChar(vol), GENERIC_READ or GENERIC_WRITE,
             FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
      if h = INVALID_HANDLE_VALUE then
        FLockLog := FLockLog + Format('  %s: cannot open (error %d)',
          [letter, GetLastError]) + LineEnding
      else
      begin
        // ask for whole-volume access BEFORE locking (afterwards it is refused)
        br := 0;
        if DeviceIoControl(h, FSCTL_ALLOW_EXTENDED_DASD_IO, nil, 0, nil, 0, br, nil) then
          FLockLog := FLockLog + Format('  %s: extended DASD I/O allowed',
            [letter]) + LineEnding
        else
          FLockLog := FLockLog + Format(
            '  %s: extended DASD I/O refused (error %d)',
            [letter, GetLastError]) + LineEnding;

        br := 0;
        locked := DeviceIoControl(h, FSCTL_LOCK_VOLUME, nil, 0, nil, 0, br, nil);
        if not locked then
        begin
          err := GetLastError;
          FLockLog := FLockLog + Format('  %s: NOT locked (error %d)',
            [letter, err]) + LineEnding;
        end
        else
          FLockLog := FLockLog + Format('  %s: locked', [letter]) + LineEnding;

        // Locking alone is NOT enough. The file-system driver keeps its own
        // cached metadata and flushes it back over our sectors the moment the
        // volume is released - which is exactly how an edit at sector 8 comes
        // back as it was. Dismounting makes the driver drop that cache and
        // re-read from the media when Windows mounts the volume again.
        br := 0;
        if DeviceIoControl(h, FSCTL_DISMOUNT_VOLUME, nil, 0, nil, 0, br, nil) then
          FLockLog := FLockLog + Format('  %s: dismounted (cache dropped)',
            [letter]) + LineEnding
        else
        begin
          FAllDismounted := False;
          FLockLog := FLockLog + Format('  %s: NOT dismounted (error %d)' +
            ' - edits inside this volume may be undone by Windows',
            [letter, GetLastError]) + LineEnding;
        end;

        // keep the handle open either way: a dismounted volume must not be
        // remounted under us while we write
        n := Length(FVolLocks); SetLength(FVolLocks, n + 1);
        FVolLocks[n] := h;
        if locked then FExclusive := True;
      end;
    end;
    p := p + Length(string(p)) + 1;
  end;
end;

procedure TRawDeviceByteSource.UnlockVolumes;
var i: Integer; br: DWORD;
begin
  for i := 0 to High(FVolLocks) do
    if FVolLocks[i] <> INVALID_HANDLE_VALUE then
    begin
      br := 0;
      DeviceIoControl(FVolLocks[i], FSCTL_UNLOCK_VOLUME, nil, 0, nil, 0, br, nil);
      CloseHandle(FVolLocks[i]);
    end;
  SetLength(FVolLocks, 0);
  FExclusive := False;
end;
{$ENDIF}

// Working buffer for the sector-aligned window. In writable mode the buffer
// itself must be sector-aligned as well (FILE_FLAG_NO_BUFFERING), which a
// plain dynamic array does not guarantee - VirtualAlloc does.
function TRawDeviceByteSource.WorkBuf(ALen: Integer): PByte;
begin
  {$IFDEF WINDOWS}
  if FWritable then
  begin
    if ALen > FMemLen then
    begin
      if FMem <> nil then VirtualFree(FMem, 0, MEM_RELEASE);
      FMemLen := ((ALen + $FFFF) div $10000) * $10000;    // round to 64 KB
      FMem := VirtualAlloc(nil, FMemLen, MEM_COMMIT or MEM_RESERVE,
                PAGE_READWRITE);
      if FMem = nil then
      begin
        FMemLen := 0;
        raise Exception.Create('Out of memory for the device buffer.');
      end;
    end;
    Exit(PByte(FMem));
  end;
  {$ENDIF}
  if Length(FBuf) < ALen then SetLength(FBuf, ALen);
  Result := PByte(@FBuf[0]);
end;

function TRawDeviceByteSource.InMountedVolume(AOfs: TFileOfs): Boolean;
{$IFDEF WINDOWS}
var i: Integer;
begin
  Result := False;
  for i := 0 to High(FVolAreas) do
    if (AOfs >= FVolAreas[i].Start) and
       (AOfs < FVolAreas[i].Start + FVolAreas[i].Len) then Exit(True);
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function TRawDeviceByteSource.VerifyReadAt(APos: TFileOfs; var ABuf;
  ALen: Integer): Integer;
var
  alignStart, alignEnd: TFileOfs;
  alignLen, ofs: Integer;
  {$IFDEF WINDOWS}
  h: THandle;
  mem: Pointer;
  got: Int64;
  nread: DWORD;
  {$ELSE}
  fs: TFileStream;
  mem: PByte;
  nread: Integer;
  {$ENDIF}
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) then Exit;
  if (FSize > 0) and (APos >= FSize) then Exit;
  if (FSize > 0) and (APos + ALen > FSize) then ALen := FSize - APos;
  alignStart := (APos div FSector) * FSector;
  alignEnd := ((APos + ALen + FSector - 1) div FSector) * FSector;
  alignLen := Integer(alignEnd - alignStart);
  ofs := Integer(APos - alignStart);

  {$IFDEF WINDOWS}
  h := CreateFile(PChar(FDevice), GENERIC_READ,
         FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
         FILE_ATTRIBUTE_NORMAL or FILE_FLAG_NO_BUFFERING, 0);
  if h = INVALID_HANDLE_VALUE then
    Exit(ReadAt(APos, ABuf, ALen));            // no second handle - do our best
  try
    mem := VirtualAlloc(nil, alignLen, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
    if mem = nil then Exit(ReadAt(APos, ABuf, ALen));
    try
      if not SetFilePointerEx(h, alignStart, @got, FILE_BEGIN) then Exit;
      nread := 0;
      if not ReadFile(h, mem^, alignLen, nread, nil) then Exit;
      if Integer(nread) < ofs then Exit;
      Result := Integer(nread) - ofs;
      if Result > ALen then Result := ALen;
      if Result > 0 then System.Move((PByte(mem) + ofs)^, ABuf, Result);
    finally
      VirtualFree(mem, 0, MEM_RELEASE);
    end;
  finally
    CloseHandle(h);
  end;
  {$ELSE}
  try
    fs := TFileStream.Create(FDevice, fmOpenRead or fmShareDenyNone);
  except
    Exit(ReadAt(APos, ABuf, ALen));
  end;
  try
    GetMem(mem, alignLen);
    try
      fs.Position := alignStart;
      nread := fs.Read(mem^, alignLen);
      if nread < ofs then Exit;
      Result := nread - ofs;
      if Result > ALen then Result := ALen;
      if Result > 0 then System.Move((mem + ofs)^, ABuf, Result);
    finally
      FreeMem(mem);
    end;
  finally
    fs.Free;
  end;
  {$ENDIF}
end;

function TRawDeviceByteSource.EjectDevice: string;
{$IFDEF WINDOWS}
type
  TPreventMediaRemoval = record PreventMediaRemoval: ByteBool; end;
var
  br: DWORD;
  pmr: TPreventMediaRemoval;
begin
  Result := '';
  if FHandle = INVALID_HANDLE_VALUE then
    Exit('The device is not open.');
  Flush;
  pmr.PreventMediaRemoval := False;
  br := 0;
  if not DeviceIoControl(FHandle, IOCTL_STORAGE_MEDIA_REMOVAL, @pmr, SizeOf(pmr),
       nil, 0, br, nil) then
    Result := Format('MEDIA_REMOVAL refused (error %d). ', [GetLastError]);
  br := 0;
  if DeviceIoControl(FHandle, IOCTL_STORAGE_EJECT_MEDIA, nil, 0, nil, 0, br, nil) then
    Result := Result + 'Device stopped - it is safe to unplug it now.'
  else
    Result := Result + Format('EJECT_MEDIA failed (error %d).', [GetLastError]);
end;
{$ELSE}
begin
  Result := 'Not available on this platform.';
end;
{$ENDIF}

function TRawDeviceByteSource.Diagnose(ATestOffset: TFileOfs): string;
var
  sec: Integer;
  ofs: TFileOfs;
  wb: PByte;
  before, after1, after2, fresh, fresh2: Byte;
  orig8, pat8, chk8: array[0..7] of Byte;
  k: Integer;
  rmwOk, byteOk, closeOk: Boolean;
  {$IFDEF WINDOWS}
  h2: THandle;
  mem2: Pointer;
  got: Int64;
  nread, nwritten: DWORD;
  {$ELSE}
  n: Integer;
  {$ENDIF}

  function Hex8(const A: array of Byte): string;
  var j: Integer;
  begin
    Result := '';
    for j := 0 to 7 do Result := Result + IntToHex(A[j], 2) + ' ';
  end;

  procedure Say(const S: string);
  begin
    Result := Result + S + LineEnding;
  end;

begin
  Result := '';
  rmwOk := False; byteOk := False;
  sec := FSector;
  if sec <= 0 then sec := 512;
  ofs := (ATestOffset div sec) * sec;          // test on a whole sector

  Say('--- HEXO device write diagnostics ---');
  Say('device        : ' + FDevice);
  Say(Format('size          : %d bytes (0x%s)', [FSize, IntToHex(FSize, 8)]));
  Say(Format('sector size   : %d', [sec]));
  Say('opened for    : ' + BoolToStr(FWritable, 'read + WRITE', 'read only'));
  {$IFDEF WINDOWS}
  Say('open flags    : NO_BUFFERING | WRITE_THROUGH (when writable)');
  Say(Format('volumes locked: %s', [BoolToStr(FExclusive, 'yes', 'NO')]));
  if FLockLog <> '' then
  begin
    Say('volume report :');
    Result := Result + FLockLog;
  end
  else
    Say('volume report : (none - no volume of this device was found)');
  Say(Format('all dismounted: %s', [BoolToStr(FAllDismounted, 'yes', 'NO')]));
  {$ELSE}
  Say('platform      : POSIX (plain file/stream access)');
  {$ENDIF}
  Say(Format('test sector   : 0x%s', [IntToHex(ofs, 8)]));
  {$IFDEF WINDOWS}
  if InMountedVolume(ofs) then
    Say('              : INSIDE a mounted volume of this disk')
  else
    Say('              : outside every mounted volume of this disk');
  {$ENDIF}

  if not FWritable then
  begin
    Say('RESULT        : opened read-only, nothing to test.');
    Exit;
  end;
  if (FSize > 0) and (ofs + sec > FSize) then
  begin
    Say('RESULT        : test offset is past the end of the device.');
    Exit;
  end;

  try
    wb := WorkBuf(sec);
  except
    on E: Exception do begin Say('buffer        : FAILED - ' + E.Message); Exit; end;
  end;

  {$IFDEF WINDOWS}
  { 1. read the sector }
  if not SetFilePointerEx(FHandle, ofs, @got, FILE_BEGIN) then
  begin Say(Format('seek          : FAILED (error %d)', [GetLastError])); Exit; end;
  nread := 0;
  if not ReadFile(FHandle, wb^, sec, nread, nil) then
  begin Say(Format('read          : FAILED (error %d)', [GetLastError])); Exit; end;
  Say(Format('read          : ok (%d bytes)', [Integer(nread)]));
  before := wb^;

  { 2. flip one byte and write the sector back }
  wb^ := before xor $FF;
  if not SetFilePointerEx(FHandle, ofs, @got, FILE_BEGIN) then
  begin Say(Format('seek #2       : FAILED (error %d)', [GetLastError])); Exit; end;
  nwritten := 0;
  if not WriteFile(FHandle, wb^, sec, nwritten, nil) then
  begin
    Say(Format('write         : FAILED (error %d)', [GetLastError]));
    Say('RESULT        : Windows refused the write - see the error code above.');
    Exit;
  end;
  Say(Format('write         : reported ok (%d bytes)', [Integer(nwritten)]));
  FlushFileBuffers(FHandle);
  Say('flush         : done');

  { 3. read it back three ways - the difference between them is the answer }
  if not SetFilePointerEx(FHandle, ofs, @got, FILE_BEGIN) then
  begin Say(Format('seek #3       : FAILED (error %d)', [GetLastError])); Exit; end;
  nread := 0;
  if not ReadFile(FHandle, wb^, sec, nread, nil) then
  begin Say(Format('read back     : FAILED (error %d)', [GetLastError])); Exit; end;
  after1 := wb^;
  Say(Format('read back #1  : 0x%s  (same handle, at once)', [IntToHex(after1, 2)]));

  // a brand-new handle: Windows must go to the storage stack again
  fresh := 0;
  if VerifyReadAt(ofs, fresh, 1) = 1 then
    Say(Format('read back #2  : 0x%s  (fresh handle)', [IntToHex(fresh, 2)]))
  else
    Say('read back #2  : FAILED (fresh handle)');

  // and once more after a pause - a lying controller drops its cache by now
  Sleep(2000);
  fresh2 := 0;
  if VerifyReadAt(ofs, fresh2, 1) = 1 then
    Say(Format('read back #3  : 0x%s  (fresh handle, after 2 s)',
      [IntToHex(fresh2, 2)]))
  else
    Say('read back #3  : FAILED (fresh handle, after 2 s)');
  Say(Format('              : was 0x%s, wrote 0x%s',
    [IntToHex(before, 2), IntToHex(before xor $FF, 2)]));

  { 4. put the original byte back, whatever happened }
  wb^ := before;
  SetFilePointerEx(FHandle, ofs, @got, FILE_BEGIN);
  nwritten := 0;
  if WriteFile(FHandle, wb^, sec, nwritten, nil) then
  begin
    FlushFileBuffers(FHandle);
    SetFilePointerEx(FHandle, ofs, @got, FILE_BEGIN);
    nread := 0;
    ReadFile(FHandle, wb^, sec, nread, nil);
    after2 := wb^;
    Say(Format('restore       : ok (byte is now 0x%s)', [IntToHex(after2, 2)]));
  end
  else
    Say(Format('restore       : FAILED (error %d) - the test byte may be left ' +
      'flipped!', [GetLastError]));
  {$ELSE}
  FStream.Position := ofs;
  n := FStream.Read(wb^, sec);
  if n <> sec then begin Say(Format('read : FAILED (%d of %d)', [n, sec])); Exit; end;
  Say(Format('read          : ok (%d bytes)', [n]));
  before := wb^;
  wb^ := before xor $FF;
  FStream.Position := ofs;
  n := FStream.Write(wb^, sec);
  if n <> sec then begin Say(Format('write : FAILED (%d of %d)', [n, sec])); Exit; end;
  Say(Format('write         : reported ok (%d bytes)', [n]));
  FStream.Position := ofs;
  FStream.Read(wb^, sec);
  after1 := wb^;
  Say(Format('read back     : 0x%s (was 0x%s, wrote 0x%s)',
    [IntToHex(after1, 2), IntToHex(before, 2), IntToHex(before xor $FF, 2)]));
  wb^ := before;
  FStream.Position := ofs;
  FStream.Write(wb^, sec);
  FStream.Position := ofs;
  FStream.Read(wb^, sec);
  after2 := wb^;
  Say(Format('restore       : ok (byte is now 0x%s)', [IntToHex(after2, 2)]));
  {$ENDIF}

  { 5. the two paths the real commit uses - this is where an edit is lost }
  Say('');
  Say('--- path the commit uses: WriteAt (read-modify-write) ---');
  if VerifyReadAt(ofs, orig8[0], 8) <> 8 then
    Say('keep original : FAILED')
  else
  begin
    Say('original 8 B  : ' + Hex8(orig8));

    for k := 0 to 7 do pat8[k] := $A5;
    try
      WriteAt(ofs, pat8[0], 8);
      Flush;
      FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
      Say('one 8-byte call, fresh read : ' + Hex8(chk8));
      Sleep(1500);
      FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
      Say('               after 1.5 s  : ' + Hex8(chk8));
      rmwOk := True;
      for k := 0 to 7 do if chk8[k] <> $A5 then rmwOk := False;
    except
      on E: Exception do begin Say('WriteAt FAILED: ' + E.Message); rmwOk := False; end;
    end;

    // and byte by byte, which is exactly what typing into the grid produces
    for k := 0 to 7 do pat8[k] := $5A;
    try
      for k := 0 to 7 do WriteAt(ofs + k, pat8[k], 1);
      Flush;
      FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
      Say('8 x 1-byte calls, fresh read: ' + Hex8(chk8));
      Sleep(1500);
      FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
      Say('               after 1.5 s  : ' + Hex8(chk8));
      byteOk := True;
      for k := 0 to 7 do if chk8[k] <> $5A then byteOk := False;
    except
      on E: Exception do begin Say('WriteAt FAILED: ' + E.Message); byteOk := False; end;
    end;

    // put the original bytes back
    try
      WriteAt(ofs, orig8[0], 8);
      Flush;
      FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
      Say('restored 8 B  : ' + Hex8(chk8));
    except
      on E: Exception do Say('restore FAILED: ' + E.Message);
    end;
  end;

  {$IFDEF WINDOWS}
  { 6. the scenario that actually loses the data: let go of every handle }
  Say('');
  Say('--- close every handle, then reopen and look again ---');
  for k := 0 to 7 do pat8[k] := $C3;
  closeOk := False;
  try
    WriteAt(ofs, pat8[0], 8);
    Flush;
    FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
    Say('written, our handle open   : ' + Hex8(chk8));

    // release everything this object holds on the device
    UnlockVolumes;
    if FHandle <> INVALID_HANDLE_VALUE then CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
    Sleep(1500);

    // now a completely independent handle, with nothing of ours open
    h2 := CreateFile(PChar(FDevice), GENERIC_READ,
            FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL or FILE_FLAG_NO_BUFFERING, 0);
    if h2 = INVALID_HANDLE_VALUE then
      Say(Format('reopen        : FAILED (error %d)', [GetLastError]))
    else
    begin
      mem2 := VirtualAlloc(nil, sec, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
      if mem2 = nil then
        Say('reopen        : out of memory')
      else
      begin
        if SetFilePointerEx(h2, ofs, @got, FILE_BEGIN) then
        begin
          nread := 0;
          if ReadFile(h2, mem2^, sec, nread, nil) and (Integer(nread) >= 8) then
          begin
            Move(mem2^, chk8[0], 8);
            Say('after close + reopen       : ' + Hex8(chk8));
            closeOk := True;
            for k := 0 to 7 do if chk8[k] <> $C3 then closeOk := False;
          end
          else
            Say(Format('read after reopen: FAILED (error %d)', [GetLastError]));
        end
        else
          Say(Format('seek after reopen: FAILED (error %d)', [GetLastError]));
        VirtualFree(mem2, 0, MEM_RELEASE);
      end;
      CloseHandle(h2);
    end;

    // take the device back so the view keeps working, and undo the test bytes
    FHandle := CreateFile(PChar(FDevice), GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_NO_BUFFERING or FILE_FLAG_WRITE_THROUGH, 0);
    if FHandle = INVALID_HANDLE_VALUE then
      Say(Format('re-acquire    : FAILED (error %d) - close the tab and open ' +
        'the device again', [GetLastError]))
    else
    begin
      if FLockVols then try LockVolumes; except end;
      try
        WriteAt(ofs, orig8[0], 8);
        Flush;
        FillChar(chk8, 8, 0); VerifyReadAt(ofs, chk8[0], 8);
        Say('restored again             : ' + Hex8(chk8));
      except
        on E: Exception do Say('restore FAILED: ' + E.Message);
      end;
    end;
  except
    on E: Exception do Say('close/reopen test FAILED: ' + E.Message);
  end;
  {$ENDIF}

  Say('');
  {$IFDEF WINDOWS}
  if not closeOk then
    Say('CLOSE CYCLE   : the bytes are LOST as soon as every handle is closed.')
  else
    Say('CLOSE CYCLE   : the bytes survive closing and reopening.');
  if not rmwOk then
    Say('RMW           : the read-modify-write path LOSES the data.')
  else if not byteOk then
    Say('RMW           : one 8-byte write sticks, but 8 single-byte writes to ' +
        'the same sector do not.')
  else
    Say('RMW           : both write paths stick.');
  if after1 <> Byte(before xor $FF) then
    Say('RESULT        : the write was SWALLOWED outright - reported ok, the ' +
        'old byte came straight back.' + LineEnding +
        '                Write-protected media, or the sector is guarded.')
  else if (fresh <> Byte(before xor $FF)) or (fresh2 <> Byte(before xor $FF)) then
    Say('RESULT        : the DEVICE IS LYING. It acknowledges the write and ' +
        'serves it from' + LineEnding +
        '                its own cache, but the media never takes it - a ' +
        'fresh read gets the' + LineEnding +
        '                old byte back. Typical of a failing or counterfeit ' +
        'flash drive.' + LineEnding +
        '                No program can write to this device.')
  else
    Say('RESULT        : the device really does accept writes at this offset.');
  {$ELSE}
  if after1 = Byte(before xor $FF) then
    Say('RESULT        : the device DOES accept writes at this offset.')
  else
    Say('RESULT        : the write was SWALLOWED.');
  {$ENDIF}
end;

constructor TRawDeviceByteSource.Create(const ADevice: string; AWritable: Boolean;
  ALockVolumes: Boolean);
{$IFDEF WINDOWS}
var
  len: Int64;
  br, access, flags: DWORD;
begin
  inherited Create;
  FSector := 512;
  FDevice := ADevice;
  FWritable := AWritable;
  FLockVols := ALockVolumes;
  FAllDismounted := True;
  FMem := nil; FMemLen := 0;
  access := GENERIC_READ;
  flags := FILE_ATTRIBUTE_NORMAL;
  if AWritable then
  begin
    access := access or GENERIC_WRITE;
    // Buffered writes to a raw device go to the cache manager and can be
    // dropped without any error - the write "succeeds" and the disk never
    // changes. Unbuffered + write-through is the only reliable way.
    flags := flags or FILE_FLAG_NO_BUFFERING or FILE_FLAG_WRITE_THROUGH;
  end;
  FHandle := CreateFile(PChar(ADevice), access,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, flags, 0);
  if FHandle = INVALID_HANDLE_VALUE then
    raise EHexOpen.CreateFor(ADevice, GetLastError);
  QuerySectorSize;
  len := 0;
  if DeviceIoControl(FHandle, IOCTL_DISK_GET_LENGTH_INFO, nil, 0,
       @len, SizeOf(len), br, nil) then
    FSize := len
  else
    FSize := 0;
  // always learn which parts of the disk belong to mounted volumes; only
  // lock/dismount them when the caller asked for it
  try LockVolumes; except end;
end;
{$ELSE}
var
  mode: Word;
begin
  inherited Create;
  FSector := 512;
  FDevice := ADevice;
  FWritable := AWritable;
  FLockVols := ALockVolumes;
  // on POSIX a block device path is read like a file (needs privileges);
  // size may be 0 for some block devices - acceptable fallback
  if AWritable then mode := fmOpenReadWrite else mode := fmOpenRead;
  FStream := TFileStream.Create(ADevice, mode or fmShareDenyNone);
  FSize := FStream.Size;
end;
{$ENDIF}

function TRawDeviceByteSource.CanWrite: Boolean;
begin
  Result := FWritable;
end;

procedure TRawDeviceByteSource.Flush;
begin
  {$IFDEF WINDOWS}
  if FWritable and (FHandle <> INVALID_HANDLE_VALUE) then FlushFileBuffers(FHandle);
  {$ENDIF}
end;

function TRawDeviceByteSource.WriteAt(APos: TFileOfs; const ABuf; ALen: Integer): Integer;
var
  alignStart, alignEnd: TFileOfs;
  alignLen, ofs: Integer;
  wb: PByte;
  {$IFDEF WINDOWS}
  got: Int64;
  nread, nwritten: DWORD;
  {$ELSE}
  nread, nwritten: Integer;
  {$ENDIF}
begin
  Result := 0;
  if not FWritable then Exit;
  if (APos < 0) or (ALen <= 0) then Exit;
  // a device never grows or shrinks - anything past the end is refused
  if (FSize > 0) and (APos >= FSize) then Exit;
  if (FSize > 0) and (APos + ALen > FSize) then ALen := FSize - APos;

  // raw devices only accept whole sectors, so patch inside a sector-aligned
  // window: read it, drop the new bytes in, write the window back
  alignStart := (APos div FSector) * FSector;
  alignEnd := ((APos + ALen + FSector - 1) div FSector) * FSector;
  alignLen := Integer(alignEnd - alignStart);
  wb := WorkBuf(alignLen);

  {$IFDEF WINDOWS}
  if not SetFilePointerEx(FHandle, alignStart, @got, FILE_BEGIN) then
    raise Exception.CreateFmt('Seek to 0x%s failed (error %d)',
      [IntToHex(alignStart, 8), GetLastError]);
  nread := 0;
  if not ReadFile(FHandle, wb^, alignLen, nread, nil) then
    raise Exception.CreateFmt('Read-before-write at 0x%s failed (error %d)',
      [IntToHex(alignStart, 8), GetLastError]);
  if Integer(nread) < alignLen then
    raise Exception.CreateFmt('Short read before write at 0x%s (%d of %d bytes)',
      [IntToHex(alignStart, 8), Integer(nread), alignLen]);

  ofs := Integer(APos - alignStart);
  Move(ABuf, (wb + ofs)^, ALen);

  if not SetFilePointerEx(FHandle, alignStart, @got, FILE_BEGIN) then
    raise Exception.CreateFmt('Seek to 0x%s failed (error %d)',
      [IntToHex(alignStart, 8), GetLastError]);
  nwritten := 0;
  if not WriteFile(FHandle, wb^, alignLen, nwritten, nil) then
    raise Exception.CreateFmt('Write at 0x%s failed (error %d)',
      [IntToHex(alignStart, 8), GetLastError]);
  if Integer(nwritten) <> alignLen then
    raise Exception.CreateFmt('Short write at 0x%s (%d of %d bytes)',
      [IntToHex(alignStart, 8), Integer(nwritten), alignLen]);
  {$ELSE}
  FStream.Position := alignStart;
  nread := FStream.Read(wb^, alignLen);
  if nread < alignLen then
    raise Exception.CreateFmt('Short read before write at 0x%s (%d of %d bytes)',
      [IntToHex(alignStart, 8), nread, alignLen]);
  ofs := Integer(APos - alignStart);
  Move(ABuf, (wb + ofs)^, ALen);
  FStream.Position := alignStart;
  nwritten := FStream.Write(wb^, alignLen);
  if nwritten <> alignLen then
    raise Exception.CreateFmt('Short write at 0x%s (%d of %d bytes)',
      [IntToHex(alignStart, 8), nwritten, alignLen]);
  {$ENDIF}
  Result := ALen;
end;

destructor TRawDeviceByteSource.Destroy;
begin
  {$IFDEF WINDOWS}
  UnlockVolumes;                 // hand the volumes back to Windows
  if FHandle <> INVALID_HANDLE_VALUE then CloseHandle(FHandle);
  if FMem <> nil then VirtualFree(FMem, 0, MEM_RELEASE);
  {$ELSE}
  FStream.Free;
  {$ENDIF}
  inherited Destroy;
end;

function TRawDeviceByteSource.Size: TFileOfs;
begin
  Result := FSize;
end;

function TRawDeviceByteSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
var
  alignStart, alignEnd: TFileOfs;
  alignLen, ofs: Integer;
  wb: PByte;
  {$IFDEF WINDOWS}
  dist, got: Int64;
  nread: DWORD;
  {$ELSE}
  nread: Integer;
  {$ENDIF}
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) then Exit;
  if (FSize > 0) and (APos >= FSize) then Exit;
  if (FSize > 0) and (APos + ALen > FSize) then ALen := FSize - APos;

  // sector-aligned window covering [APos, APos+ALen)
  alignStart := (APos div FSector) * FSector;
  alignEnd := ((APos + ALen + FSector - 1) div FSector) * FSector;
  alignLen := Integer(alignEnd - alignStart);
  wb := WorkBuf(alignLen);

  {$IFDEF WINDOWS}
  dist := alignStart;
  if SetFilePointerEx(FHandle, dist, @got, FILE_BEGIN) then
  begin
    nread := 0;
    if not ReadFile(FHandle, wb^, alignLen, nread, nil) then Exit;
  end
  else
    Exit;
  {$ELSE}
  FStream.Position := alignStart;
  nread := FStream.Read(wb^, alignLen);
  {$ENDIF}

  ofs := Integer(APos - alignStart);
  if Integer(nread) < ofs then Exit;
  Result := Integer(nread) - ofs;
  if Result > ALen then Result := ALen;
  if Result > 0 then
    System.Move((wb + ofs)^, ABuf, Result);
end;

{ TEditByteSource - non-destructive piece-table editing layer ---------------- }

constructor TEditByteSource.Create(ABack: TByteSource; AOwnsBack: Boolean);
begin
  inherited Create;
  FBack := ABack;
  FOwnsBack := AOwnsBack;
  FAdd := TMemoryStream.Create;
  FSize := 0;
  if Assigned(FBack) then FSize := FBack.Size;
  SetLength(FPieces, 1);
  FPieces[0].Kind := pkOrig;
  FPieces[0].Start := 0;
  FPieces[0].Len := FSize;
  if FSize = 0 then SetLength(FPieces, 0);
  FModified := False;
end;

destructor TEditByteSource.Destroy;
begin
  if FOwnsBack then FBack.Free;
  FAdd.Free;
  inherited Destroy;
end;

function TEditByteSource.Size: TFileOfs;
begin
  Result := FSize;
end;

procedure TEditByteSource.RecomputeSize;
var i: Integer;
begin
  FSize := 0;
  for i := 0 to High(FPieces) do FSize := FSize + FPieces[i].Len;
end;

function TEditByteSource.ClonePieces: TPieceArray;
begin
  Result := Copy(FPieces, 0, Length(FPieces));
end;

function TEditByteSource.PieceIndexAt(APos: TFileOfs): Integer;
var i: Integer; cum: TFileOfs;
begin
  // returns index of the piece that STARTS at APos (requires a boundary there),
  // or Length(FPieces) if APos = FSize
  cum := 0;
  for i := 0 to High(FPieces) do
  begin
    if cum = APos then Exit(i);
    cum := cum + FPieces[i].Len;
  end;
  Result := Length(FPieces);   // APos = FSize (append point)
end;

procedure TEditByteSource.SplitAt(APos: TFileOfs);
var i: Integer; cum, ofs: TFileOfs; np: TPieceArray;
begin
  if (APos <= 0) or (APos >= FSize) then Exit;   // boundary already exists
  cum := 0;
  for i := 0 to High(FPieces) do
  begin
    if (APos > cum) and (APos < cum + FPieces[i].Len) then
    begin
      ofs := APos - cum;
      SetLength(np, Length(FPieces) + 1);
      if i > 0 then Move(FPieces[0], np[0], i * SizeOf(TPiece));
      np[i] := FPieces[i];
      np[i].Len := ofs;
      np[i + 1] := FPieces[i];
      np[i + 1].Start := FPieces[i].Start + ofs;
      np[i + 1].Len := FPieces[i].Len - ofs;
      if i < High(FPieces) then
        Move(FPieces[i + 1], np[i + 2], (High(FPieces) - i) * SizeOf(TPiece));
      FPieces := np;
      Exit;
    end;
    cum := cum + FPieces[i].Len;
  end;
end;

function TEditByteSource.AppendToAdd(const AData; ALen: Integer): TFileOfs;
begin
  Result := FAdd.Size;
  FAdd.Position := FAdd.Size;
  FAdd.WriteBuffer(AData, ALen);
end;

procedure TEditByteSource.DoInsert(APos: TFileOfs; AAddStart, ALen: TFileOfs);
var idx, i: Integer; np: TPieceArray;
begin
  SplitAt(APos);
  idx := PieceIndexAt(APos);
  SetLength(np, Length(FPieces) + 1);
  for i := 0 to idx - 1 do np[i] := FPieces[i];
  np[idx].Kind := pkAdd;
  np[idx].Start := AAddStart;
  np[idx].Len := ALen;
  for i := idx to High(FPieces) do np[i + 1] := FPieces[i];
  FPieces := np;
  RecomputeSize;
end;

procedure TEditByteSource.DoDelete(APos, ALen: TFileOfs);
var i0, i1, i, n: Integer; np: TPieceArray;
begin
  if ALen <= 0 then Exit;
  if APos >= FSize then Exit;
  if APos + ALen > FSize then ALen := FSize - APos;
  SplitAt(APos);
  SplitAt(APos + ALen);
  i0 := PieceIndexAt(APos);
  i1 := PieceIndexAt(APos + ALen);
  n := Length(FPieces) - (i1 - i0);
  SetLength(np, n);
  for i := 0 to i0 - 1 do np[i] := FPieces[i];
  for i := i1 to High(FPieces) do np[i - (i1 - i0)] := FPieces[i];
  FPieces := np;
  RecomputeSize;
end;

procedure TEditByteSource.PushUndo;
var n: Integer;
begin
  n := Length(FUndo);
  SetLength(FUndo, n + 1);
  FUndo[n].Pieces := ClonePieces;
  FUndo[n].Sz := FSize;
  SetLength(FRedo, 0);   // any new edit invalidates redo
end;

procedure TEditByteSource.Restore(const AState: TUndoState);
begin
  FPieces := Copy(AState.Pieces, 0, Length(AState.Pieces));
  FSize := AState.Sz;
end;

procedure TEditByteSource.InsertData(APos: TFileOfs; const AData; ALen: Integer);
var addStart: TFileOfs;
begin
  if FFixedLength then Exit;      // would grow the image - never on a device
  if ALen <= 0 then Exit;
  if APos < 0 then APos := 0;
  if APos > FSize then APos := FSize;
  PushUndo;
  addStart := AppendToAdd(AData, ALen);
  DoInsert(APos, addStart, ALen);
  FModified := True;
end;

procedure TEditByteSource.DeleteRange(APos, ALen: TFileOfs);
begin
  if FFixedLength then Exit;      // would shrink the image
  if (ALen <= 0) or (APos < 0) or (APos >= FSize) then Exit;
  PushUndo;
  DoDelete(APos, ALen);
  FModified := True;
end;

procedure TEditByteSource.Overwrite(APos: TFileOfs; const AData; ALen: Integer);
var addStart, d: TFileOfs;
begin
  if ALen <= 0 then Exit;
  if APos < 0 then APos := 0;
  if APos > FSize then APos := FSize;
  // on a fixed-length image an overwrite may not run past the end: clip it,
  // so the piece table can never come out longer than the backing store
  if FFixedLength then
  begin
    if APos >= FSize then Exit;
    if APos + ALen > FSize then ALen := Integer(FSize - APos);
    if ALen <= 0 then Exit;
  end;
  PushUndo;
  addStart := AppendToAdd(AData, ALen);
  d := ALen;
  if APos + d > FSize then d := FSize - APos;   // don't delete past end
  if d > 0 then DoDelete(APos, d);
  DoInsert(APos, addStart, ALen);
  FModified := True;
end;

function TEditByteSource.ByteModified(APos: TFileOfs): Boolean;
var i: Integer; cum: TFileOfs;
begin
  Result := False;
  if (APos < 0) or (APos >= FSize) then Exit;
  cum := 0;
  for i := 0 to High(FPieces) do
  begin
    if (APos >= cum) and (APos < cum + FPieces[i].Len) then
      Exit(FPieces[i].Kind = pkAdd);
    cum := cum + FPieces[i].Len;
  end;
end;

function TEditByteSource.CanUndo: Boolean;
begin
  Result := Length(FUndo) > 0;
end;

function TEditByteSource.CanRedo: Boolean;
begin
  Result := Length(FRedo) > 0;
end;

procedure TEditByteSource.Undo;
var n, m: Integer;
begin
  n := Length(FUndo);
  if n = 0 then Exit;
  m := Length(FRedo);
  SetLength(FRedo, m + 1);
  FRedo[m].Pieces := ClonePieces;
  FRedo[m].Sz := FSize;
  Restore(FUndo[n - 1]);
  SetLength(FUndo, n - 1);
  FModified := (Length(FUndo) > 0);
end;

procedure TEditByteSource.Redo;
var n, m: Integer;
begin
  m := Length(FRedo);
  if m = 0 then Exit;
  n := Length(FUndo);
  SetLength(FUndo, n + 1);
  FUndo[n].Pieces := ClonePieces;
  FUndo[n].Sz := FSize;
  Restore(FRedo[m - 1]);
  SetLength(FRedo, m - 1);
  FModified := True;
end;

function TEditByteSource.ReadAt(APos: TFileOfs; var ABuf; ALen: Integer): Integer;
var
  i: Integer;
  cum, pstart, pend, take, srcOfs: TFileOfs;
  dst: PByte;
  rangeEnd: TFileOfs;
begin
  Result := 0;
  if (APos < 0) or (ALen <= 0) or (APos >= FSize) then Exit;
  if APos + ALen > FSize then ALen := FSize - APos;
  rangeEnd := APos + ALen;
  dst := @ABuf;
  cum := 0;
  for i := 0 to High(FPieces) do
  begin
    pstart := cum;
    pend := cum + FPieces[i].Len;
    cum := pend;
    if pend <= APos then Continue;
    if pstart >= rangeEnd then Break;
    // overlap [max(APos,pstart), min(rangeEnd,pend))
    if APos > pstart then srcOfs := APos - pstart else srcOfs := 0;
    if rangeEnd < pend then take := rangeEnd - (pstart + srcOfs)
    else take := pend - (pstart + srcOfs);
    if take <= 0 then Continue;
    if FPieces[i].Kind = pkOrig then
    begin
      if Assigned(FBack) then
        FBack.ReadAt(FPieces[i].Start + srcOfs, dst^, Integer(take));
    end
    else
      Move(PByte(FAdd.Memory)[FPieces[i].Start + srcOfs], dst^, take);
    Inc(dst, take);
    Result := Result + Integer(take);
  end;
end;

procedure TEditByteSource.SaveToStream(AStream: TStream);
var
  i: Integer;
  remaining, srcPos: TFileOfs;
  buf: array[0..65535] of Byte;
  chunk, r: Integer;
begin
  for i := 0 to High(FPieces) do
  begin
    remaining := FPieces[i].Len;
    srcPos := FPieces[i].Start;
    while remaining > 0 do
    begin
      if remaining > SizeOf(buf) then chunk := SizeOf(buf)
      else chunk := Integer(remaining);
      if FPieces[i].Kind = pkOrig then
      begin
        r := 0;
        if Assigned(FBack) then r := FBack.ReadAt(srcPos, buf, chunk);
        if r <= 0 then Break;
      end
      else
      begin
        Move(PByte(FAdd.Memory)[srcPos], buf, chunk);
        r := chunk;
      end;
      AStream.WriteBuffer(buf, r);
      Inc(srcPos, r);
      remaining := remaining - r;
    end;
  end;
end;

procedure TEditByteSource.SaveToFile(const AFileName: string);
var fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    SaveToStream(fs);
  finally
    fs.Free;
  end;
end;

function TEditByteSource.ModifiedRanges: TModRanges;
var
  i, n: Integer;
  outPos: TFileOfs;
begin
  Result := nil;
  n := 0;
  outPos := 0;
  for i := 0 to High(FPieces) do
  begin
    if FPieces[i].Kind = pkAdd then
    begin
      // merge with the previous run when they touch
      if (n > 0) and (Result[n - 1].Start + Result[n - 1].Len = outPos) then
        Result[n - 1].Len := Result[n - 1].Len + FPieces[i].Len
      else
      begin
        Inc(n); SetLength(Result, n);
        Result[n - 1].Start := outPos;
        Result[n - 1].Len := FPieces[i].Len;
      end;
    end;
    outPos := outPos + FPieces[i].Len;
  end;
end;

function TEditByteSource.ModifiedByteCount: TFileOfs;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(FPieces) do
    if FPieces[i].Kind = pkAdd then Result := Result + FPieces[i].Len;
end;

function TEditByteSource.CanCommit: Boolean;
begin
  Result := Assigned(FBack) and FBack.CanWrite and (FSize = FBack.Size);
end;

procedure TEditByteSource.CommitToBacking;
const
  WCHUNK = 1024 * 1024;         // multiple of any sector size
var
  i, k: Integer;
  outPos, srcPos, remaining: TFileOfs;
  chunk, w: Integer;
  vbuf: array of Byte;
begin
  if not Assigned(FBack) or not FBack.CanWrite then
    raise Exception.Create('Backing store is read-only.');
  // a length change would shift everything after it; refuse rather than
  // scribble a whole device over
  if FSize <> FBack.Size then
    raise Exception.CreateFmt(
      'Size changed (%d vs %d) - cannot write back in place.', [FSize, FBack.Size]);

  outPos := 0;
  for i := 0 to High(FPieces) do
  begin
    if FPieces[i].Kind = pkAdd then
    begin
      remaining := FPieces[i].Len;
      srcPos := FPieces[i].Start;
      while remaining > 0 do
      begin
        if remaining > WCHUNK then chunk := WCHUNK else chunk := Integer(remaining);
        w := FBack.WriteAt(outPos, PByte(FAdd.Memory)[srcPos], chunk);
        if w <> chunk then
          raise Exception.CreateFmt('Wrote %d of %d bytes at 0x%s.',
            [w, chunk, IntToHex(outPos, 8)]);
        Inc(outPos, chunk); Inc(srcPos, chunk); remaining := remaining - chunk;
      end;
    end
    else
      outPos := outPos + FPieces[i].Len;
  end;
  FBack.Flush;

  // ---- read the written bytes back and compare -----------------------------
  // A raw-device write can report success and change nothing at all (Windows
  // dropping a cached write, a locked sector, a write-protected stick). The
  // only honest way to know is to look.
  SetLength(vbuf, WCHUNK);
  outPos := 0;
  for i := 0 to High(FPieces) do
  begin
    if FPieces[i].Kind = pkAdd then
    begin
      remaining := FPieces[i].Len;
      srcPos := FPieces[i].Start;
      while remaining > 0 do
      begin
        if remaining > WCHUNK then chunk := WCHUNK else chunk := Integer(remaining);
        // a fresh handle, so neither the OS nor the drive's own cache can
        // hand us back what we just wrote instead of what is on the media
        if FBack.VerifyReadAt(outPos, vbuf[0], chunk) <> chunk then
          raise EHexVerify.CreateAt(outPos);
        if not CompareMem(@vbuf[0], PByte(FAdd.Memory) + srcPos, chunk) then
        begin
          for k := 0 to chunk - 1 do
            if vbuf[k] <> PByte(FAdd.Memory)[srcPos + k] then
              raise EHexVerify.CreateAt(outPos + k);
          raise EHexVerify.CreateAt(outPos);
        end;
        Inc(outPos, chunk); Inc(srcPos, chunk); remaining := remaining - chunk;
      end;
    end
    else
      outPos := outPos + FPieces[i].Len;
  end;

  // the edits ARE the backing store now: collapse to one clean original piece
  SetLength(FPieces, 1);
  FPieces[0].Kind := pkOrig;
  FPieces[0].Start := 0;
  FPieces[0].Len := FSize;
  if FSize = 0 then SetLength(FPieces, 0);
  FAdd.Clear;
  SetLength(FUndo, 0);          // nothing to undo - it is on the disk
  SetLength(FRedo, 0);
  FModified := False;
end;

procedure TEditByteSource.Rebase(ANewBack: TByteSource; AOwnsBack: Boolean);
begin
  if FOwnsBack then FreeAndNil(FBack);
  FBack := ANewBack;
  FOwnsBack := AOwnsBack;
  FAdd.Clear;
  FSize := 0;
  if Assigned(FBack) then FSize := FBack.Size;
  if FSize > 0 then
  begin
    SetLength(FPieces, 1);
    FPieces[0].Kind := pkOrig;
    FPieces[0].Start := 0;
    FPieces[0].Len := FSize;
  end
  else
    SetLength(FPieces, 0);
  SetLength(FUndo, 0);
  SetLength(FRedo, 0);
  FModified := False;
end;

procedure TEditByteSource.CloseBacking;
begin
  if FOwnsBack then FreeAndNil(FBack) else FBack := nil;
  FOwnsBack := False;
end;

function TEditByteSource.BackingFileName: string;
begin
  if FBack is TFileByteSource then Result := TFileByteSource(FBack).FileName
  else Result := '';
end;

{ THexView ------------------------------------------------------------------- }

constructor THexView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;

  // set all fields BEFORE Width/Height: assigning bounds triggers Resize ->
  // UpdateMetrics, which must see a valid FGroupSize/FBytesPerRow
  FBytesPerRow := 16;
  FGroupSize := 8;
  FUtf8CharPane := True;
  FHexCopySpaces := True;
  FInsertMode := False;
  FLowNibble := False;
  FEdit := nil;
  FActiveField := hfHex;
  FOffsetChars := 8;
  FCharW := 8;
  FRowH := 16;

  Width := 640;
  Height := 400;

  FColOffsetBk := clBtnFace;
  FColOffsetTx := clGrayText;
  FColHexBk := clWindow;
  FColHexTx := clWindowText;
  FColCharBk := clWindow;
  FColCharTx := clNavy;
  FColSelBk := clHighlight;
  FColSelTx := clHighlightText;
  FColRule := clBtnShadow;
  FColModTx := clRed;

  Font.Name := 'Courier New';
  Font.Size := 10;

  FScrollBar := nil;   // created in CreateWnd, once we have a real parent form
end;

destructor THexView.Destroy;
begin
  if FOwnsSource then
    FreeAndNil(FSource);
  inherited Destroy;
end;

function THexView.GetSize: TFileOfs;
begin
  if Assigned(FSource) then Result := FSource.Size else Result := 0;
end;

procedure THexView.SetByteSource(ASource: TByteSource; AOwns: Boolean);
begin
  if FOwnsSource then FreeAndNil(FSource);
  FSource := ASource;
  FOwnsSource := AOwns;
  if ASource is TEditByteSource then FEdit := TEditByteSource(ASource)
  else FEdit := nil;
  FTopRow := 0;
  FCurPos := 0;
  FHasSel := False;
  FLowNibble := False;
  UpdateMetrics;
  UpdateScrollBar;
  Invalidate;
end;

procedure THexView.CloseSource;
begin
  if FOwnsSource then FreeAndNil(FSource)
  else FSource := nil;
  FEdit := nil;
  FOwnsSource := False;
  FTopRow := 0;
  FCurPos := 0;
  FSelAnchor := 0;
  FHasSel := False;
  FLowNibble := False;
  SetLength(FLastPattern, 0);
  UpdateMetrics;
  UpdateScrollBar;
  Invalidate;
  DoSelChange;
end;

procedure THexView.SetSource(AValue: TByteSource);
begin
  SetByteSource(AValue, False);
end;

{ editing -------------------------------------------------------------------- }

procedure THexView.OpenEditable(const AFileName: string; InMemory: Boolean);
var back: TByteSource;
begin
  if InMemory then back := TMemByteSource.CreateFromFile(AFileName)
  else back := TFileByteSource.Create(AFileName);
  SetByteSource(TEditByteSource.Create(back, True), True);
end;

function THexView.IsEditable: Boolean;
begin
  Result := Assigned(FEdit);
end;

procedure THexView.OpenDevice(const ADevice: string; AWritable: Boolean;
  ALockVolumes: Boolean);
var dev: TRawDeviceByteSource;
begin
  dev := TRawDeviceByteSource.Create(ADevice, AWritable, ALockVolumes);
  if AWritable then
  begin
    // writable: full edit layer on top, but the length is nailed down
    SetByteSource(TEditByteSource.Create(dev, True), True);
    FEdit.FixedLength := True;
    FInsertMode := False;           // insert cannot exist on a fixed image
  end
  else
    SetByteSource(dev, True);       // read-only: no edit layer at all
end;

function THexView.IsFixedLength: Boolean;
begin
  Result := Assigned(FEdit) and FEdit.FixedLength;
end;

function THexView.CanCommit: Boolean;
begin
  Result := Assigned(FEdit) and FEdit.CanCommit;
end;

function THexView.ModifiedRanges: TModRanges;
begin
  if Assigned(FEdit) then Result := FEdit.ModifiedRanges else Result := nil;
end;

function THexView.ModifiedByteCount: TFileOfs;
begin
  if Assigned(FEdit) then Result := FEdit.ModifiedByteCount else Result := 0;
end;

procedure THexView.CommitToBacking;
begin
  if not Assigned(FEdit) then Exit;
  FEdit.CommitToBacking;
  Invalidate;
  DoEditChange;
end;

function THexView.IsModified: Boolean;
begin
  Result := Assigned(FEdit) and FEdit.Modified;
end;

function THexView.BackingFileName: string;
begin
  Result := '';
  if Assigned(FEdit) then Result := FEdit.BackingFileName
  else if FSource is TFileByteSource then Result := TFileByteSource(FSource).FileName;
end;

function THexView.CanUndo: Boolean;
begin
  Result := Assigned(FEdit) and FEdit.CanUndo;
end;

function THexView.CanRedo: Boolean;
begin
  Result := Assigned(FEdit) and FEdit.CanRedo;
end;

procedure THexView.DoEditChange;
begin
  if Assigned(FOnEditChange) then FOnEditChange(Self);
end;

procedure THexView.AfterEdit;
begin
  UpdateMetrics;
  if FCurPos > DataSize then FCurPos := DataSize;
  ClampTop;
  UpdateScrollBar;
  EnsureVisible(FCurPos);
  Invalidate;
  DoSelChange;
  DoEditChange;
end;

procedure THexView.SetInsertMode(AValue: Boolean);
begin
  // a fixed-length image (device) has no insert mode to switch to
  if AValue and IsFixedLength then AValue := False;
  if FInsertMode = AValue then Exit;
  FInsertMode := AValue;
  FLowNibble := False;
  DoEditChange;
end;

procedure THexView.EditHexNibble(ADigit: Integer);
var cur, nb: Byte;
begin
  if not Assigned(FEdit) then Exit;

  if FInsertMode and not FLowNibble then
  begin
    nb := ADigit shl 4;
    FEdit.InsertData(FCurPos, nb, 1);
    FLowNibble := True;
    AfterEdit;
    Exit;
  end;

  cur := 0;
  if FCurPos < FEdit.Size then FEdit.ReadAt(FCurPos, cur, 1);

  if not FLowNibble then
  begin
    nb := (ADigit shl 4) or (cur and $0F);
    if FCurPos >= FEdit.Size then FEdit.InsertData(FCurPos, nb, 1)
    else FEdit.Overwrite(FCurPos, nb, 1);
    FLowNibble := True;
  end
  else
  begin
    nb := (cur and $F0) or ADigit;
    FEdit.Overwrite(FCurPos, nb, 1);
    FLowNibble := False;
    SetCursorPos(FCurPos + 1, False);
  end;
  AfterEdit;
end;

procedure THexView.EditCharByte(AByte: Byte);
begin
  if not Assigned(FEdit) then Exit;
  FLowNibble := False;
  if FInsertMode or (FCurPos >= FEdit.Size) then
    FEdit.InsertData(FCurPos, AByte, 1)
  else
    FEdit.Overwrite(FCurPos, AByte, 1);
  SetCursorPos(FCurPos + 1, False);
  AfterEdit;
end;

procedure THexView.DeleteSelection;
begin
  if not Assigned(FEdit) or not FHasSel or (SelCount <= 0) then Exit;
  FLowNibble := False;
  FEdit.DeleteRange(SelStart, SelCount);
  FHasSel := False;
  SetCursorPos(SelStart, False);
  AfterEdit;
end;

procedure THexView.OverwriteSelection(const AData: TBytes);
begin
  if not Assigned(FEdit) or not FHasSel or (SelCount <= 0) then Exit;
  if Length(AData) = 0 then Exit;
  FEdit.Overwrite(SelStart, AData[0], Length(AData));
  // keep the (possibly same-length) region selected
  SelectRange(SelStart, SelStart + Length(AData) - 1);
  AfterEdit;
end;

function ApplyByteOp(AOp: THexOp; v, oper: Byte): Byte;
var c: Integer;
begin
  case AOp of
    hopNot: Result := not v;
    hopAnd: Result := v and oper;
    hopOr:  Result := v or oper;
    hopXor: Result := v xor oper;
    hopAdd: Result := Byte(v + oper);
    hopSub: Result := Byte(v - oper);
    hopMul: Result := Byte(v * oper);
    hopDiv: if oper <> 0 then Result := v div oper else Result := v;
    hopMod: if oper <> 0 then Result := v mod oper else Result := v;
    hopShl: Result := Byte(v shl (oper and 7));
    hopShr: Result := v shr (oper and 7);
    hopRol:
      begin
        c := oper and 7;
        if c = 0 then Result := v
        else Result := Byte((v shl c) or (v shr (8 - c)));
      end;
    hopRor:
      begin
        c := oper and 7;
        if c = 0 then Result := v
        else Result := Byte((v shr c) or (v shl (8 - c)));
      end;
    hopNeg: Result := Byte(0 - v);
    hopUpper:
      if (v >= Ord('a')) and (v <= Ord('z')) then Result := v - 32 else Result := v;
    hopLower:
      if (v >= Ord('A')) and (v <= Ord('Z')) then Result := v + 32 else Result := v;
    hopInvCase:
      if (v >= Ord('a')) and (v <= Ord('z')) then Result := v - 32
      else if (v >= Ord('A')) and (v <= Ord('Z')) then Result := v + 32
      else Result := v;
    hopFill: Result := oper;
  else Result := v;
  end;
end;

procedure THexView.ApplySelectionOp(AOp: THexOp; AOperand: Byte);
var b: TBytes; i, n: Integer; t: Byte;
begin
  if not Assigned(FEdit) or not FHasSel or (SelCount <= 0) then Exit;
  if SelCount > MaxInt then Exit;             // in-memory transform cap
  b := ReadSelection;
  n := Length(b);
  if n = 0 then Exit;
  if AOp = hopFlip then
  begin
    for i := 0 to (n div 2) - 1 do
    begin t := b[i]; b[i] := b[n - 1 - i]; b[n - 1 - i] := t; end;
  end
  else
    for i := 0 to n - 1 do b[i] := ApplyByteOp(AOp, b[i], AOperand);
  FEdit.Overwrite(SelStart, b[0], n);
  AfterEdit;
end;

procedure THexView.DeleteAtCursor(ABackspace: Boolean);
begin
  if not Assigned(FEdit) then Exit;
  FLowNibble := False;
  if FHasSel and (SelCount > 0) then begin DeleteSelection; Exit; end;
  if ABackspace then
  begin
    if FCurPos = 0 then Exit;
    FEdit.DeleteRange(FCurPos - 1, 1);
    SetCursorPos(FCurPos - 1, False);
  end
  else
  begin
    if FCurPos >= FEdit.Size then Exit;
    FEdit.DeleteRange(FCurPos, 1);
  end;
  AfterEdit;
end;

procedure THexView.Undo;
begin
  if Assigned(FEdit) and FEdit.CanUndo then
  begin
    FEdit.Undo;
    FLowNibble := False;
    if FCurPos > DataSize then FCurPos := DataSize;
    AfterEdit;
  end;
end;

procedure THexView.Redo;
begin
  if Assigned(FEdit) and FEdit.CanRedo then
  begin
    FEdit.Redo;
    FLowNibble := False;
    if FCurPos > DataSize then FCurPos := DataSize;
    AfterEdit;
  end;
end;

procedure THexView.SaveToFile(const AFileName: string);
var tmp: string;
begin
  if not Assigned(FEdit) then Exit;
  if FEdit.BackingFileName <> '' then
  begin
    // file-backed: write to temp, release original handle, swap, reopen
    tmp := AFileName + '.hxtmp';
    FEdit.SaveToFile(tmp);
    FEdit.CloseBacking;
    if SysUtils.FileExists(AFileName) then SysUtils.DeleteFile(AFileName);
    SysUtils.RenameFile(tmp, AFileName);
  end
  else
    FEdit.SaveToFile(AFileName);   // mem/raw backing - no handle conflict
  FEdit.Rebase(TFileByteSource.Create(AFileName), True);
  FLowNibble := False;
  AfterEdit;
end;

procedure THexView.KeyPress(var Key: char);
begin
  if not Assigned(FEdit) then begin inherited KeyPress(Key); Exit; end;
  if FActiveField = hfHex then
  begin
    case Key of
      '0'..'9': EditHexNibble(Ord(Key) - Ord('0'));
      'a'..'f': EditHexNibble(Ord(Key) - Ord('a') + 10);
      'A'..'F': EditHexNibble(Ord(Key) - Ord('A') + 10);
    else
      begin inherited KeyPress(Key); Exit; end;
    end;
    Key := #0;
  end
  else if FActiveField = hfChar then
  begin
    if Key >= ' ' then
    begin
      EditCharByte(Ord(Key) and $FF);
      Key := #0;
    end
    else
      inherited KeyPress(Key);
  end
  else
    inherited KeyPress(Key);
end;

procedure THexView.LoadFromFile(const AFileName: string; InMemory: Boolean);
begin
  if InMemory then
    SetByteSource(TMemByteSource.CreateFromFile(AFileName), True)
  else
    SetByteSource(TFileByteSource.Create(AFileName), True);
end;

procedure THexView.SetBytesPerRow(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if AValue > 256 then AValue := 256;
  if FBytesPerRow = AValue then Exit;
  FBytesPerRow := AValue;
  UpdateMetrics;
  UpdateScrollBar;
  Invalidate;
end;

procedure THexView.SetGroupSize(AValue: Integer);
begin
  if AValue < 1 then AValue := 1;
  if FGroupSize = AValue then Exit;
  FGroupSize := AValue;
  UpdateMetrics;
  Invalidate;
end;

procedure THexView.SetUtf8CharPane(AValue: Boolean);
begin
  if FUtf8CharPane = AValue then Exit;
  FUtf8CharPane := AValue;
  Invalidate;
end;

{ geometry ------------------------------------------------------------------- }

function THexView.TotalRows: TFileOfs;
begin
  if DataSize <= 0 then Result := 1
  else Result := (DataSize + FBytesPerRow - 1) div FBytesPerRow;
end;

function THexView.VisibleRows: Integer;
begin
  if FRowH <= 0 then Result := 1
  else Result := Max(1, ClientHeight div FRowH);
end;

function THexView.MaxTopRow: TFileOfs;
begin
  Result := TotalRows - VisibleRows;
  if Result < 0 then Result := 0;
end;

procedure THexView.ClampTop;
begin
  if FTopRow > MaxTopRow then FTopRow := MaxTopRow;
  if FTopRow < 0 then FTopRow := 0;
end;

procedure THexView.UpdateMetrics;
var
  q: TFileOfs;
  n: Integer;
begin
  if HandleAllocated then
  begin
    Canvas.Font := Font;
    FCharW := Canvas.TextWidth('0');
    FRowH := Canvas.TextHeight('0') + 2;
  end;
  if FCharW <= 0 then FCharW := 8;
  if FRowH <= 0 then FRowH := 16;
  FTextTop := 1;

  // offset digit count: enough hex digits for the last offset, min 8, even
  n := 8;
  q := DataSize;
  while q > (TFileOfs(1) shl (n * 4)) do Inc(n, 2);
  FOffsetChars := n;

  FViewW := ClientWidth;
  if Assigned(FScrollBar) and FScrollBar.Visible then
    FViewW := FViewW - FScrollBar.Width;

  FHexX0 := (FOffsetChars + 2) * FCharW;                 // "OFFSET: "
  FCharX0 := HexByteX(FBytesPerRow) + FCharW;            // one gap after hex
end;

// left pixel of hex byte AIndex ("AA " per byte, extra blank per group)
function THexView.HexByteX(AIndex: Integer): Integer;
var grp: Integer;
begin
  grp := FGroupSize;
  if grp < 1 then grp := 1;
  Result := FHexX0 + (AIndex * 3 + (AIndex div grp)) * FCharW;
end;

function THexView.CharByteX(AIndex: Integer): Integer;
begin
  Result := FCharX0 + AIndex * FCharW;
end;

{ scroll --------------------------------------------------------------------- }

procedure THexView.UpdateScrollBar;
var
  tr, vr: TFileOfs;
  mx: Integer;
begin
  if not Assigned(FScrollBar) then Exit;
  FScrollBar.Top := 0;
  FScrollBar.Left := ClientWidth - FScrollBar.Width;
  FScrollBar.Height := ClientHeight;

  tr := TotalRows;
  vr := VisibleRows;
  FUpdatingScroll := True;
  try
    if tr <= vr then
    begin
      FScrollBar.Enabled := False;
      FScrollBar.Min := 0;
      FScrollBar.Max := 0;
      FScrollBar.Position := 0;
    end
    else
    begin
      FScrollBar.Enabled := True;
      // map Int64 row range onto a 32-bit scrollbar; keep a large but safe range
      if (tr - vr) > High(Integer) then mx := High(Integer)
      else mx := Integer(tr - vr);
      FScrollBar.Min := 0;
      FScrollBar.Max := mx;
      if MaxTopRow > 0 then
        FScrollBar.Position := Integer(Round(FTopRow / MaxTopRow * mx))
      else
        FScrollBar.Position := 0;
    end;
  finally
    FUpdatingScroll := False;
  end;
end;

procedure THexView.ScrollBarScroll(Sender: TObject; ScrollCode: TScrollCode;
  var ScrollPos: Integer);
var mx: Integer;
begin
  if FUpdatingScroll then Exit;
  case ScrollCode of
    scLineUp:    FTopRow := FTopRow - 1;
    scLineDown:  FTopRow := FTopRow + 1;
    scPageUp:    FTopRow := FTopRow - VisibleRows;
    scPageDown:  FTopRow := FTopRow + VisibleRows;
    scTop:       FTopRow := 0;
    scBottom:    FTopRow := MaxTopRow;
  else
    // scPosition / scTrack: map thumb fraction back to Int64 rows
    mx := FScrollBar.Max;
    if mx > 0 then
      FTopRow := Round(ScrollPos / mx * MaxTopRow)
    else
      FTopRow := 0;
  end;
  ClampTop;
  UpdateScrollBar;
  Invalidate;
end;

procedure THexView.ScrollToRow(ARow: TFileOfs);
begin
  FTopRow := ARow;
  ClampTop;
  UpdateScrollBar;
  Invalidate;
end;

procedure THexView.EnsureVisible(APos: TFileOfs);
var r: TFileOfs;
begin
  if APos < 0 then APos := 0;
  r := APos div FBytesPerRow;
  if r < FTopRow then FTopRow := r
  else if r >= FTopRow + VisibleRows then FTopRow := r - VisibleRows + 1;
  ClampTop;
  UpdateScrollBar;
end;

{ selection ------------------------------------------------------------------ }

function THexView.SelStart: TFileOfs;
begin
  if FHasSel then Result := Min(FSelAnchor, FCurPos) else Result := FCurPos;
end;

function THexView.SelEnd: TFileOfs;
begin
  if FHasSel then Result := Max(FSelAnchor, FCurPos) else Result := FCurPos - 1;
end;

function THexView.SelCount: TFileOfs;
begin
  if FHasSel then Result := SelEnd - SelStart + 1 else Result := 0;
end;

procedure THexView.DoSelChange;
begin
  if Assigned(FOnSelChange) then FOnSelChange(Self);
end;

procedure THexView.SetCursorPos(APos: TFileOfs; AExtendSel: Boolean);
begin
  if APos < 0 then APos := 0;
  if APos > DataSize then APos := DataSize;
  if DataSize > 0 then
    if APos >= DataSize then APos := DataSize - 1;

  if AExtendSel then
  begin
    if not FHasSel then
    begin
      FSelAnchor := FCurPos;
      FHasSel := True;
    end;
  end
  else
    FHasSel := False;

  FCurPos := APos;
  FLowNibble := False;
  EnsureVisible(FCurPos);
  Invalidate;
  DoSelChange;
end;

procedure THexView.SelectRange(AStart, AEnd: TFileOfs);
begin
  if not Assigned(FSource) then Exit;
  if AStart < 0 then AStart := 0;
  if AEnd >= DataSize then AEnd := DataSize - 1;
  if AEnd < AStart then Exit;
  FSelAnchor := AStart;
  FCurPos := AEnd;
  FHasSel := True;
  EnsureVisible(AStart);
  EnsureVisible(AEnd);
  Invalidate;
  DoSelChange;
end;

procedure THexView.GotoOffset(APos: TFileOfs);
begin
  FHasSel := False;
  SetCursorPos(APos, False);
end;

{ streaming search ----------------------------------------------------------- }

class function THexView.ParseHexPattern(const S: string; out ABytes: TBytes): Boolean;
var
  i, hi: Integer;
  c: Char;
  v: Integer;
  cnt: Integer;
begin
  SetLength(ABytes, Length(S) div 2 + 1);
  ABytes := nil;
  cnt := 0;
  hi := -1;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    case c of
      '0'..'9': v := Ord(c) - Ord('0');
      'a'..'f': v := Ord(c) - Ord('a') + 10;
      'A'..'F': v := Ord(c) - Ord('A') + 10;
      ' ', #9, ',', '-', ':', '$', 'x', 'X': Continue;   // separators, ignore
    else
      begin SetLength(ABytes, 0); Exit(False); end;
    end;
    if hi < 0 then hi := v
    else
    begin
      ABytes[cnt] := (hi shl 4) or v;
      Inc(cnt);
      hi := -1;
    end;
  end;
  if hi >= 0 then begin SetLength(ABytes, 0); Exit(False); end;  // odd nibble count
  SetLength(ABytes, cnt);
  Result := cnt > 0;
end;

function THexView.FindBytes(const APattern; APatLen: Integer; AStart: TFileOfs;
  ACaseInsensitive: Boolean): TFileOfs;
const
  CHUNK = 65536;
var
  pat: PByte;
  buf: array of Byte;
  bufStart, pos: TFileOfs;
  got, i, j: Integer;
  sz: TFileOfs;

  function Fold(b: Byte): Byte; inline;
  begin
    if ACaseInsensitive and (b >= Ord('A')) and (b <= Ord('Z')) then
      Result := b or $20
    else
      Result := b;
  end;

var
  ok: Boolean;
begin
  Result := -1;
  pat := @APattern;
  if (APatLen <= 0) or not Assigned(FSource) then Exit;
  sz := DataSize;
  if AStart < 0 then AStart := 0;
  if AStart + APatLen > sz then Exit;

  buf := nil;
  SetLength(buf, CHUNK + APatLen - 1);
  pos := AStart;
  while pos + APatLen <= sz do
  begin
    bufStart := pos;
    got := FSource.ReadAt(bufStart, buf[0], Length(buf));
    if got < APatLen then Exit;
    // scan this window; last APatLen-1 bytes overlap into next read
    for i := 0 to got - APatLen do
    begin
      ok := True;
      for j := 0 to APatLen - 1 do
        if Fold(buf[i + j]) <> Fold(pat[j]) then begin ok := False; Break; end;
      if ok then Exit(bufStart + i);
    end;
    Inc(pos, got - APatLen + 1);
  end;
end;

function THexView.FindFirst(const APattern; APatLen: Integer;
  ACaseInsensitive: Boolean): Boolean;
var p: TFileOfs;
begin
  SetLength(FLastPattern, APatLen);
  if APatLen > 0 then System.Move(APattern, FLastPattern[0], APatLen);
  FLastCaseIns := ACaseInsensitive;
  p := FindBytes(APattern, APatLen, FCurPos, ACaseInsensitive);
  Result := p >= 0;
  if Result then SelectRange(p, p + APatLen - 1);
end;

function THexView.FindNext: Boolean;
var p: TFileOfs;
begin
  Result := False;
  if Length(FLastPattern) = 0 then Exit;
  p := FindBytes(FLastPattern[0], Length(FLastPattern), FCurPos + 1, FLastCaseIns);
  Result := p >= 0;
  if Result then SelectRange(p, p + Length(FLastPattern) - 1);
end;

{ clipboard / export --------------------------------------------------------- }

function THexView.ReadSelection: TBytes;
var
  n, chunk: TFileOfs;
  off: TFileOfs;
  r: Integer;
begin
  Result := nil;
  SetLength(Result, 0);
  if not FHasSel or not Assigned(FSource) then Exit;
  n := SelCount;
  if n <= 0 then Exit;
  if n > MaxInt then n := MaxInt;          // hard cap for in-memory ops
  SetLength(Result, n);
  off := 0;
  while off < n do
  begin
    chunk := n - off;
    if chunk > 65536 then chunk := 65536;
    r := FSource.ReadAt(SelStart + off, Result[off], Integer(chunk));
    if r <= 0 then Break;
    Inc(off, r);
  end;
  SetLength(Result, off);
end;

procedure THexView.CopySelectionHex;
var
  b: TBytes;
  s: string;
  i, step: Integer;
begin
  b := ReadSelection;
  if Length(b) = 0 then Exit;
  s := '';
  if FHexCopySpaces then
  begin
    step := 3;
    SetLength(s, Length(b) * 3);
  end
  else
  begin
    step := 2;
    SetLength(s, Length(b) * 2);
  end;
  for i := 0 to High(b) do
  begin
    s[i * step + 1] := HEXDIG[b[i] shr 4];
    s[i * step + 2] := HEXDIG[b[i] and 15];
    if FHexCopySpaces then s[i * step + 3] := ' ';
  end;
  Clipboard.AsText := TrimRight(s);
end;

procedure THexView.CopySelectionText;
var
  b: TBytes;
  s: string;
  i: Integer;
begin
  b := ReadSelection;
  if Length(b) = 0 then Exit;
  s := '';
  SetLength(s, Length(b));
  for i := 0 to High(b) do
    if b[i] < 32 then s[i + 1] := '.' else s[i + 1] := Chr(b[i]);
  Clipboard.AsText := s;
end;

procedure THexView.ExportSelectionBin(const AFile: string);
var
  fs: TFileStream;
  buf: array[0..65535] of Byte;
  n, off: TFileOfs;
  chunk, r: Integer;
begin
  if not FHasSel or not Assigned(FSource) then Exit;
  n := SelCount;
  fs := TFileStream.Create(AFile, fmCreate);
  try
    off := 0;
    while off < n do
    begin
      chunk := SizeOf(buf);
      if n - off < chunk then chunk := Integer(n - off);
      r := FSource.ReadAt(SelStart + off, buf, chunk);
      if r <= 0 then Break;
      fs.WriteBuffer(buf, r);
      Inc(off, r);
    end;
  finally
    fs.Free;
  end;
end;

procedure THexView.ExportSelectionC(const AFile, AVarName: string);
var
  sl: TStringList;
  b: TBytes;
  i: Integer;
  line: string;
begin
  b := ReadSelection;
  sl := TStringList.Create;
  try
    sl.Add(Format('/* %s: %d bytes from offset 0x%s */',
      [AVarName, Length(b), IntToHex(SelStart, 8)]));
    sl.Add(Format('unsigned char %s[%d] = {', [AVarName, Length(b)]));
    line := '  ';
    for i := 0 to High(b) do
    begin
      line := line + '0x' + HexPair[b[i]][0] + HexPair[b[i]][1];
      if i < High(b) then line := line + ', ';
      if (i mod 12) = 11 then begin sl.Add(line); line := '  '; end;
    end;
    if Trim(line) <> '' then sl.Add(line);
    sl.Add('};');
    sl.SaveToFile(AFile);
  finally
    sl.Free;
  end;
end;

procedure THexView.ExportSelectionPascal(const AFile, AVarName: string);
var
  sl: TStringList;
  b: TBytes;
  i: Integer;
  line: string;
begin
  b := ReadSelection;
  sl := TStringList.Create;
  try
    sl.Add(Format('{ %s: %d bytes from offset 0x%s }',
      [AVarName, Length(b), IntToHex(SelStart, 8)]));
    if Length(b) = 0 then
      sl.Add(Format('const %s: array[0..0] of Byte = ($00);', [AVarName]))
    else
    begin
      sl.Add(Format('const %s: array[0..%d] of Byte = (', [AVarName, High(b)]));
      line := '  ';
      for i := 0 to High(b) do
      begin
        line := line + '$' + HexPair[b[i]][0] + HexPair[b[i]][1];
        if i < High(b) then line := line + ', ';
        if (i mod 12) = 11 then begin sl.Add(line); line := '  '; end;
      end;
      if Trim(line) <> '' then sl.Add(line);
      sl.Add(');');
    end;
    sl.SaveToFile(AFile);
  finally
    sl.Free;
  end;
end;

{ data ----------------------------------------------------------------------- }

function THexView.ReadRow(ARow: TFileOfs; var ABuf; AMax: Integer): Integer;
begin
  if Assigned(FSource) then
    Result := FSource.ReadAt(ARow * FBytesPerRow, ABuf, AMax)
  else
    Result := 0;
end;

{ mouse hit-testing ---------------------------------------------------------- }

procedure THexView.PosToField(X, Y: Integer; out APos: TFileOfs;
  out AField: THexField);
var
  row: TFileOfs;
  i, bx: Integer;
begin
  AField := hfNone;
  APos := -1;
  if FRowH <= 0 then Exit;
  row := FTopRow + (Y div FRowH);

  if (X >= FHexX0) and (X < FCharX0) then
  begin
    for i := 0 to FBytesPerRow - 1 do
    begin
      bx := HexByteX(i);
      if (X >= bx) and (X < bx + 2 * FCharW + FCharW div 2) then
      begin
        AField := hfHex;
        APos := row * FBytesPerRow + i;
        Exit;
      end;
    end;
  end
  else if X >= FCharX0 then
  begin
    i := (X - FCharX0) div FCharW;
    if (i >= 0) and (i < FBytesPerRow) then
    begin
      AField := hfChar;
      APos := row * FBytesPerRow + i;
    end;
  end;
end;

{ UTF-8-aware character glyph over a small window ---------------------------- }

function THexView.CellGlyph(const AWin: array of Byte; AWinLen, AIdx: Integer): string;

  function SeqLen(b: Byte): Integer;
  begin
    if b < $80 then Result := 1
    else if (b >= $C2) and (b <= $DF) then Result := 2
    else if (b >= $E0) and (b <= $EF) then Result := 3
    else if (b >= $F0) and (b <= $F4) then Result := 4
    else Result := 0;
  end;

  function IsCont(b: Byte): Boolean;
  begin
    Result := (b and $C0) = $80;
  end;

  function Latin1(b: Byte): string;
  begin
    if b < $80 then Result := Chr(b)
    else
    begin
      SetLength(Result, 2);
      Result[1] := Chr($C0 or (b shr 6));
      Result[2] := Chr($80 or (b and $3F));
    end;
  end;

var
  b: Byte;
  n, j, L, k: Integer;
  ok: Boolean;
begin
  b := AWin[AIdx];
  if b < $80 then
  begin
    if b < 32 then Result := '.' else Result := Chr(b);
    Exit;
  end;
  if not FUtf8CharPane then
  begin
    Result := Latin1(b);
    Exit;
  end;
  if IsCont(b) then
  begin
    for j := 1 to 3 do
    begin
      L := AIdx - j;
      if L < 0 then Break;
      n := SeqLen(AWin[L]);
      if (n > 1) and (n > j) and (L + n <= AWinLen) then
      begin
        ok := True;
        for k := 1 to n - 1 do
          if not IsCont(AWin[L + k]) then begin ok := False; Break; end;
        if ok then begin Result := ''; Exit; end;
      end;
    end;
    Result := Latin1(b);
    Exit;
  end;
  n := SeqLen(b);
  if (n > 1) and (AIdx + n <= AWinLen) then
  begin
    ok := True;
    for k := 1 to n - 1 do
      if not IsCont(AWin[AIdx + k]) then begin ok := False; Break; end;
    if ok then
    begin
      SetLength(Result, n);
      for k := 0 to n - 1 do Result[k + 1] := Chr(AWin[AIdx + k]);
      Exit;
    end;
  end;
  Result := Latin1(b);
end;

{ paint ---------------------------------------------------------------------- }

procedure THexView.InitializeWnd;
begin
  inherited InitializeWnd;
  // create the scrollbar only after THexView's own handle exists and it is
  // parented to a realized form; doing it earlier gives the child WS_CHILD
  // with WndParent=0 -> "control has no parent window"
  if FScrollBar = nil then
  begin
    FScrollBar := TScrollBar.Create(Self);
    FScrollBar.Kind := sbVertical;
    FScrollBar.TabStop := False;
    FScrollBar.Parent := Self;
    FScrollBar.OnScroll := @ScrollBarScroll;
  end;
  UpdateMetrics;
  UpdateScrollBar;
end;

procedure THexView.Paint;
var
  rowIdx, visRows, i, y, bx, xl, xr: Integer;
  row: TFileOfs;
  rowStart, cellPos, winStart: TFileOfs;
  rowBuf: array[0..255] of Byte;
  win: array[0..271] of Byte;         // BPR + up to 3+3 context, capped
  rowLen, winLen, winIdx: Integer;
  ofsStr, glyph: string;
  fg, bg: TColor;
  inSel: Boolean;
  r: TRect;
begin
  UpdateMetrics;

  Canvas.Brush.Style := bsSolid;

  // background panes
  Canvas.Brush.Color := FColHexBk;
  Canvas.FillRect(0, 0, FViewW, ClientHeight);
  Canvas.Brush.Color := FColOffsetBk;
  Canvas.FillRect(0, 0, FHexX0 - FCharW, ClientHeight);

  visRows := VisibleRows + 1;
  Canvas.Font := Font;

  for rowIdx := 0 to visRows - 1 do
  begin
    row := FTopRow + rowIdx;
    if row >= TotalRows then Break;
    y := rowIdx * FRowH;
    rowStart := row * FBytesPerRow;
    rowLen := ReadRow(row, rowBuf, FBytesPerRow);
    if rowLen <= 0 then Continue;

    // context window for cross-row UTF-8 (3 bytes before/after)
    winStart := rowStart - 3;
    if winStart < 0 then winStart := 0;
    winLen := 0;
    if Assigned(FSource) then
      winLen := FSource.ReadAt(winStart, win, FBytesPerRow + 6);

    // offset
    ofsStr := IntToHex(rowStart, FOffsetChars) + ':';
    Canvas.Brush.Color := FColOffsetBk;
    Canvas.Font.Color := FColOffsetTx;
    Canvas.TextOut(FCharW div 2, y + FTextTop, ofsStr);

    // hex + char cells
    for i := 0 to rowLen - 1 do
    begin
      cellPos := rowStart + i;
      inSel := FHasSel and (cellPos >= SelStart) and (cellPos <= SelEnd);

      fg := FColHexTx;
      bg := FColHexBk;
      if inSel then begin fg := FColSelTx; bg := FColSelBk; end
      else if Assigned(FEdit) and FEdit.ByteModified(cellPos) then fg := FColModTx
      else if Assigned(FOnByteFormat) then
        FOnByteFormat(Self, cellPos, rowBuf[i], fg, bg);

      // hex pair - fill continuously across inter-byte / group gaps so a
      // selected run reads as one solid block (no "comb")
      bx := HexByteX(i);
      xl := bx;
      xr := bx + 2 * FCharW;
      if inSel then
      begin
        if i = 0 then xl := FHexX0 - FCharW div 2;           // fill leading gap, clear of offset
        if (i < rowLen - 1) and (cellPos + 1 <= SelEnd) then
          xr := HexByteX(i + 1);                             // bridge the gap to next byte
      end;
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := bg;
      Canvas.FillRect(Rect(xl, y, xr, y + FRowH));
      Canvas.Font.Color := fg;
      r := Rect(bx, y, bx + 2 * FCharW, y + FRowH);
      Canvas.TextRect(r, bx, y + FTextTop, HexPair[rowBuf[i]][0] +
        HexPair[rowBuf[i]][1]);

      // char cell (UTF-8 aware)
      winIdx := Integer(rowStart - winStart) + i;
      if (winIdx >= 0) and (winIdx < winLen) then
        glyph := CellGlyph(win, winLen, winIdx)
      else
        glyph := '';
      bx := CharByteX(i);
      if inSel then begin fg := FColSelTx; bg := FColSelBk; end
      else begin
        fg := FColCharTx; bg := FColCharBk;
        if Assigned(FEdit) and FEdit.ByteModified(cellPos) then fg := FColModTx;
      end;
      r := Rect(bx, y, bx + FCharW, y + FRowH);
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := bg;
      Canvas.FillRect(r);
      Canvas.Font.Color := fg;
      Canvas.TextRect(r, bx, y + FTextTop, glyph);
    end;

    // cursor caret (thin frame on the active field cell)
    if (FCurPos >= rowStart) and (FCurPos < rowStart + FBytesPerRow) then
    begin
      i := Integer(FCurPos - rowStart);
      if FActiveField = hfChar then
        r := Rect(CharByteX(i), y, CharByteX(i) + FCharW, y + FRowH)
      else
        r := Rect(HexByteX(i), y, HexByteX(i) + 2 * FCharW, y + FRowH);
      Canvas.Pen.Color := FColRule;
      Canvas.Brush.Style := bsClear;
      Canvas.Rectangle(r);
      Canvas.Brush.Style := bsSolid;
    end;
  end;

  // vertical rule between hex and char panes only
  Canvas.Pen.Color := FColRule;
  Canvas.Line(FCharX0 - FCharW div 2, 0, FCharX0 - FCharW div 2, ClientHeight);
end;

procedure THexView.Resize;
begin
  inherited Resize;
  UpdateMetrics;
  UpdateScrollBar;
  ClampTop;
end;

{ input ---------------------------------------------------------------------- }

function THexView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
var lines: Integer;
begin
  lines := 3;
  if WheelDelta > 0 then FTopRow := FTopRow - lines
  else FTopRow := FTopRow + lines;
  ClampTop;
  UpdateScrollBar;
  Invalidate;
  Result := True;
end;

procedure THexView.KeyDown(var Key: Word; Shift: TShiftState);
var ext: Boolean;
begin
  inherited KeyDown(Key, Shift);
  ext := ssShift in Shift;
  case Key of
    VK_LEFT:  SetCursorPos(FCurPos - 1, ext);
    VK_RIGHT: SetCursorPos(FCurPos + 1, ext);
    VK_UP:    SetCursorPos(FCurPos - FBytesPerRow, ext);
    VK_DOWN:  SetCursorPos(FCurPos + FBytesPerRow, ext);
    VK_PRIOR: SetCursorPos(FCurPos - TFileOfs(VisibleRows) * FBytesPerRow, ext);
    VK_NEXT:  SetCursorPos(FCurPos + TFileOfs(VisibleRows) * FBytesPerRow, ext);
    VK_HOME:
      if ssCtrl in Shift then SetCursorPos(0, ext)
      else SetCursorPos(FCurPos - (FCurPos mod FBytesPerRow), ext);
    VK_END:
      if ssCtrl in Shift then SetCursorPos(DataSize - 1, ext)
      else SetCursorPos(FCurPos - (FCurPos mod FBytesPerRow) + FBytesPerRow - 1, ext);
    VK_TAB:
      begin
        if FActiveField = hfHex then FActiveField := hfChar
        else FActiveField := hfHex;
        FLowNibble := False;
        Invalidate;
      end;
    VK_F3: FindNext;
    VK_INSERT:
      if Assigned(FEdit) and not (ssCtrl in Shift) and not (ssShift in Shift) then
        InsertMode := not FInsertMode;
    VK_DELETE: if Assigned(FEdit) then DeleteAtCursor(False);
    VK_BACK:   if Assigned(FEdit) then DeleteAtCursor(True);
    Ord('Z'): if (ssCtrl in Shift) and Assigned(FEdit) then Undo;
    Ord('Y'): if (ssCtrl in Shift) and Assigned(FEdit) then Redo;
  end;
end;

procedure THexView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var p: TFileOfs; f: THexField;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
  if Button = mbLeft then
  begin
    PosToField(X, Y, p, f);
    if f <> hfNone then
    begin
      if f <> hfNone then FActiveField := f;
      SetCursorPos(p, ssShift in Shift);
    end;
  end;
end;

procedure THexView.MouseMove(Shift: TShiftState; X, Y: Integer);
var p: TFileOfs; f: THexField;
begin
  inherited MouseMove(Shift, X, Y);
  if ssLeft in Shift then
  begin
    PosToField(X, Y, p, f);
    if f <> hfNone then SetCursorPos(p, True);
  end;
end;

initialization
  InitHexPair;

end.
