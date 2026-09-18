program t_about;
{$mode objfpc}{$H+}
// harness: renders the About dialog headless so the layout can be eyeballed,
// with the real app icon loaded to exercise the Windows branch of the layout
uses Interfaces, Forms, uhexabout, SysUtils;
begin
  Application.Initialize;
  if FileExists('hexviewdemo.ico') then
    try Application.Icon.LoadFromFile('hexviewdemo.ico'); except end;
  ShowAbout(nil);
end.
