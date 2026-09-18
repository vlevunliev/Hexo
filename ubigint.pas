unit ubigint;

{$mode objfpc}{$H+}
{$WARN 5089 OFF}   // "result of managed type not initialized" - spurious for SetLength+fill
{$WARN 5093 OFF}

// Minimal unsigned big-integer arithmetic for RSA-style modular exponentiation.
// Base 2^32 limbs, little-endian (limb 0 = least significant). Zero = empty.
// Pure Pascal, no dependencies. Not constant-time - for a calculator, not for
// production key operations.

interface

uses
  SysUtils;

type
  TLimbs = array of LongWord;

function BiFromHex(const S: string): TLimbs;
function BiToHex(const A: TLimbs): string;
function BiIsZero(const A: TLimbs): Boolean;
function BiCompare(const A, B: TLimbs): Integer;   // -1,0,1 by magnitude
function BiAdd(const A, B: TLimbs): TLimbs;
function BiSub(const A, B: TLimbs): TLimbs;         // assumes A >= B
function BiMul(const A, B: TLimbs): TLimbs;
procedure BiDivMod(const U, V: TLimbs; out Q, R: TLimbs);
function BiMod(const A, M: TLimbs): TLimbs;
function BiModPow(const Base, Exp, Modulus: TLimbs): TLimbs;

implementation

function BiNorm(const A: TLimbs): TLimbs;
var n: Integer;
begin
  Result := nil;
  Result := nil;
  n := Length(A);
  while (n > 0) and (A[n - 1] = 0) do Dec(n);
  Result := Copy(A, 0, n);
end;

function BiIsZero(const A: TLimbs): Boolean;
begin
  Result := Length(BiNorm(A)) = 0;
end;

function HexVal(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else Result := -1;
  end;
end;

function BiFromHex(const S: string): TLimbs;
var
  clean: string;
  i, limbCount, li, shift: Integer;
  v: Integer;
begin
  clean := '';
  for i := 1 to Length(S) do
    if HexVal(S[i]) >= 0 then clean := clean + S[i];
  // strip leading zeros
  i := 1;
  while (i < Length(clean)) and (clean[i] = '0') do Inc(i);
  clean := Copy(clean, i, Length(clean));
  if (clean = '') or (clean = '0') then Exit(nil);

  limbCount := (Length(clean) + 7) div 8;
  SetLength(Result, limbCount);
  for i := 0 to limbCount - 1 do Result[i] := 0;

  // process from the rightmost hex digit
  li := 0; shift := 0;
  for i := Length(clean) downto 1 do
  begin
    v := HexVal(clean[i]);
    Result[li] := Result[li] or (LongWord(v) shl shift);
    Inc(shift, 4);
    if shift = 32 then begin shift := 0; Inc(li); end;
  end;
  Result := BiNorm(Result);
end;

function BiToHex(const A: TLimbs): string;
var n, i: Integer; t: TLimbs; s: string;
begin
  t := BiNorm(A);
  n := Length(t);
  if n = 0 then Exit('0');
  Result := IntToHex(t[n - 1], 1);   // top limb, no leading zeros
  for i := n - 2 downto 0 do
  begin
    s := IntToHex(t[i], 8);
    Result := Result + s;
  end;
end;

function BiCompare(const A, B: TLimbs): Integer;
var na, nb, i: Integer;
begin
  na := Length(BiNorm(A)); nb := Length(BiNorm(B));
  if na <> nb then
  begin if na < nb then Exit(-1) else Exit(1); end;
  for i := na - 1 downto 0 do
    if A[i] <> B[i] then
    begin if A[i] < B[i] then Exit(-1) else Exit(1); end;
  Result := 0;
end;

function BiAdd(const A, B: TLimbs): TLimbs;
var n, i: Integer; s, carry: QWord;
begin
  n := Length(A); if Length(B) > n then n := Length(B);
  SetLength(Result, n + 1);
  carry := 0;
  for i := 0 to n - 1 do
  begin
    s := carry;
    if i < Length(A) then s := s + A[i];
    if i < Length(B) then s := s + B[i];
    Result[i] := LongWord(s);
    carry := s shr 32;
  end;
  Result[n] := LongWord(carry);
  Result := BiNorm(Result);
end;

function BiSub(const A, B: TLimbs): TLimbs;
var i: Integer; diff: Int64; bv: Int64; borrow: Int64;
begin
  SetLength(Result, Length(A));
  borrow := 0;
  for i := 0 to High(A) do
  begin
    if i < Length(B) then bv := B[i] else bv := 0;
    diff := Int64(A[i]) - bv - borrow;
    if diff < 0 then begin diff := diff + $100000000; borrow := 1; end
    else borrow := 0;
    Result[i] := LongWord(diff);
  end;
  Result := BiNorm(Result);
end;

function BiMul(const A, B: TLimbs): TLimbs;
var i, j: Integer; cur, carry: QWord;
begin
  if (Length(A) = 0) or (Length(B) = 0) then Exit(nil);
  SetLength(Result, Length(A) + Length(B));
  for i := 0 to High(Result) do Result[i] := 0;
  for i := 0 to High(A) do
  begin
    carry := 0;
    for j := 0 to High(B) do
    begin
      cur := QWord(A[i]) * B[j] + Result[i + j] + carry;
      Result[i + j] := LongWord(cur);
      carry := cur shr 32;
    end;
    Result[i + Length(B)] := LongWord(carry);
  end;
  Result := BiNorm(Result);
end;

function BiShlBits(const A: TLimbs; s: Integer): TLimbs;
var i: Integer; cur, carry: QWord;
begin
  if (s = 0) or (Length(A) = 0) then Exit(Copy(A, 0, Length(A)));
  SetLength(Result, Length(A) + 1);
  carry := 0;
  for i := 0 to High(A) do
  begin
    cur := (QWord(A[i]) shl s) or carry;
    Result[i] := LongWord(cur);
    carry := cur shr 32;
  end;
  Result[High(A) + 1] := LongWord(carry);
  Result := BiNorm(Result);
end;

function BiShrBits(const A: TLimbs; s: Integer): TLimbs;
var i: Integer; cur, carry: QWord; mask: QWord;
begin
  if (s = 0) or (Length(A) = 0) then Exit(Copy(A, 0, Length(A)));
  SetLength(Result, Length(A));
  carry := 0;
  mask := (QWord(1) shl s) - 1;
  for i := High(A) downto 0 do
  begin
    cur := (carry shl 32) or A[i];
    Result[i] := LongWord(cur shr s);
    carry := A[i] and mask;
  end;
  Result := BiNorm(Result);
end;

function BiDivModSmall(const A: TLimbs; b: LongWord; out r: LongWord): TLimbs;
var i: Integer; cur: QWord;
begin
  SetLength(Result, Length(A));
  r := 0;
  for i := High(A) downto 0 do
  begin
    cur := (QWord(r) shl 32) or A[i];
    Result[i] := LongWord(cur div b);
    r := LongWord(cur mod b);
  end;
  Result := BiNorm(Result);
end;

procedure BiDivMod(const U, V: TLimbs; out Q, R: TLimbs);
var
  vn, un: TLimbs;
  n, m, i, j, shift: Integer;
  qhat, rhat, p, mulCarry, carry, s2: QWord;
  borrow, diff: Int64;
  addBack: Boolean;
  rem1: LongWord;
  vtop: LongWord;
begin
  Q := nil; R := nil;
  vn := BiNorm(V);
  un := BiNorm(U);
  if Length(vn) = 0 then Exit;                 // div by zero -> 0,0
  if BiCompare(un, vn) < 0 then begin Q := nil; R := un; Exit; end;

  n := Length(vn);
  if n = 1 then
  begin
    Q := BiDivModSmall(un, vn[0], rem1);
    if rem1 = 0 then R := nil else begin SetLength(R, 1); R[0] := rem1; end;
    Exit;
  end;

  m := Length(un) - n;

  // normalize so top limb of divisor has its MSB set
  shift := 0; vtop := vn[n - 1];
  while (vtop and $80000000) = 0 do begin vtop := vtop shl 1; Inc(shift); end;
  vn := BiShlBits(vn, shift);
  SetLength(vn, n);                            // stays n limbs
  un := BiShlBits(un, shift);
  SetLength(un, m + n + 1);                    // ensure extra top limb (zero-padded)

  SetLength(Q, m + 1);
  for i := 0 to m do Q[i] := 0;

  for j := m downto 0 do
  begin
    p := (QWord(un[j + n]) shl 32) or un[j + n - 1];
    qhat := p div vn[n - 1];
    rhat := p mod vn[n - 1];
    while (qhat > $FFFFFFFF) or
          (qhat * vn[n - 2] > ((rhat shl 32) or un[j + n - 2])) do
    begin
      Dec(qhat);
      rhat := rhat + vn[n - 1];
      if rhat > $FFFFFFFF then Break;
    end;

    // multiply and subtract qhat*vn from un[j..j+n]
    mulCarry := 0; borrow := 0;
    for i := 0 to n - 1 do
    begin
      p := qhat * vn[i] + mulCarry;
      mulCarry := p shr 32;
      diff := Int64(un[j + i]) - Int64(LongWord(p)) - borrow;
      if diff < 0 then begin diff := diff + $100000000; borrow := 1; end
      else borrow := 0;
      un[j + i] := LongWord(diff);
    end;
    diff := Int64(un[j + n]) - Int64(mulCarry) - borrow;
    if diff < 0 then begin diff := diff + $100000000; addBack := True; end
    else addBack := False;
    un[j + n] := LongWord(diff);

    if addBack then
    begin
      Dec(qhat);
      carry := 0;
      for i := 0 to n - 1 do
      begin
        s2 := QWord(un[j + i]) + vn[i] + carry;
        un[j + i] := LongWord(s2);
        carry := s2 shr 32;
      end;
      un[j + n] := LongWord(QWord(un[j + n]) + carry);
    end;

    Q[j] := LongWord(qhat);
  end;

  // remainder = un[0..n-1] denormalized
  SetLength(R, n);
  for i := 0 to n - 1 do R[i] := un[i];
  R := BiShrBits(R, shift);
  R := BiNorm(R);
  Q := BiNorm(Q);
end;

function BiMod(const A, M: TLimbs): TLimbs;
var q, r: TLimbs;
begin
  BiDivMod(A, M, q, r);
  Result := r;
end;

function BiModPow(const Base, Exp, Modulus: TLimbs): TLimbs;
var b, e, q, tmp: TLimbs;
begin
  if BiIsZero(Modulus) then Exit(nil);
  SetLength(Result, 1); Result[0] := 1;
  Result := BiMod(Result, Modulus);       // handles modulus = 1 -> 0
  BiDivMod(Base, Modulus, q, b);          // b := Base mod Modulus
  e := BiNorm(Exp);
  while not BiIsZero(e) do
  begin
    if (e[0] and 1) = 1 then
    begin
      tmp := BiMul(Result, b);
      Result := BiMod(tmp, Modulus);
    end;
    tmp := BiMul(b, b);
    b := BiMod(tmp, Modulus);
    e := BiShrBits(e, 1);
  end;
end;

end.
