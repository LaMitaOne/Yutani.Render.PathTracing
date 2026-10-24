{*******************************************************************************
  Yutani Particle Demo Form
********************************************************************************
  VCL Wrapper demonstrating the Yutani Particle engine.
  Dynamically constructs UI controls and embeds the threaded Raylib renderer.
  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}
unit Unit1;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, Vcl.Controls, Vcl.Forms,
  Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, raylib, PathTracingSample;

type
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
  private
    FEngine: TPathTracingSample;
    btnStart: TButton;
    pnlUI: TPanel;
    pnlRender: TPanel;
    tbFPS: TTrackBar;
    lblFPS: TLabel;
    FPSTimer: TTimer;
    procedure OnStartClick(Sender: TObject);
    procedure OnFPSTracking(Sender: TObject);
    procedure OnFPSTimer(Sender: TObject);
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation
{$R *.dfm}

procedure TForm1.FormCreate(Sender: TObject);
begin
  Caption := 'Yutani Particle Demo';
  Self.DoubleBuffered := True;
  Width := 1000;
  Height := 700;
  // 1. Render Panel: Hosts the Raylib child window
  pnlRender := TPanel.Create(Self);
  pnlRender.Parent := Self;
  pnlRender.Align := alClient;
  pnlRender.BevelOuter := bvNone;
  pnlRender.Caption := '';
  // 2. UI Panel: Contains buttons and trackbar
  pnlUI := TPanel.Create(Self);
  pnlUI.Parent := Self;
  pnlUI.Align := alTop;
  pnlUI.Height := 65;
  pnlUI.BevelOuter := bvNone;
  pnlUI.Caption := '';
  pnlUI.DoubleBuffered := True;
  pnlUI.BringToFront;
  // 3. Start Button
  btnStart := TButton.Create(Self);
  btnStart.Parent := pnlUI;
  btnStart.Caption := 'Start Engine';
  btnStart.Width := 120;
  btnStart.Left := 20;
  btnStart.Top := 10;
  btnStart.OnClick := OnStartClick;

  // 6. FPS Label
  lblFPS := TLabel.Create(Self);
  lblFPS.Parent := pnlUI;
  lblFPS.Caption := 'Target: 60 | Real: 0 FPS';
  lblFPS.Left := 340;
  lblFPS.Top := 15;
  lblFPS.Width := 200;
  lblFPS.Font.Size := 10;
  // 7. FPS TrackBar
  tbFPS := TTrackBar.Create(Self);
  tbFPS.Parent := pnlUI;
  tbFPS.Min := 1;
  tbFPS.Max := 5000;
  tbFPS.Position := 60;
  tbFPS.Width := 120;
  tbFPS.Left := 540;
  tbFPS.Top := 10;
  tbFPS.OnChange := OnFPSTracking;


  // 12. UI Update Timer
  FPSTimer := TTimer.Create(Self);
  FPSTimer.Interval := 500;
  FPSTimer.OnTimer := OnFPSTimer;
  FPSTimer.Enabled := True;
  // Instantiate engine and bind to Render Panel handle
  FEngine := TPathTracingSample.Create(pnlRender.Handle);
  FEngine.SetDimensions(pnlRender.Width, pnlRender.Height);
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  if Assigned(FEngine) and Assigned(pnlRender) then
    FEngine.SetDimensions(pnlRender.Width, pnlRender.Height);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if Assigned(FEngine) then
  begin
    FEngine.StopEngine;
    FEngine.Terminate;
    FEngine.WaitFor;
    FEngine.Free;
  end;
end;

procedure TForm1.OnStartClick(Sender: TObject);
begin
  if Assigned(FEngine) then
  begin
    FEngine.StartEngine;
  end;
end;

procedure TForm1.OnFPSTracking(Sender: TObject);
begin
  if Assigned(FEngine) and Assigned(tbFPS) then
    FEngine.SetFPS(Round(tbFPS.Position));
end;

procedure TForm1.OnFPSTimer(Sender: TObject);
begin
  if Assigned(FEngine) and Assigned(lblFPS) then
    lblFPS.Caption := Format('Target: %d | Real: %d FPS', [FEngine.TargetFPS, FEngine.RealFPS]);
end;

end.

