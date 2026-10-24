{*******************************************************************************
  PathTracingSample Demo Wrapper
********************************************************************************
  A minimal threaded VCL Raylib wrapper designed to demonstrate the
  Yutani.Render.PathTracing unit.

  The wrapper core (THighResTimer, hybrid sleep + spin-wait frame pacing,
  VCL window embedding, SetParent trick) is identical to uParticleEngine.pas.
  Only the engine instance type and the per-frame scene logic changed:
  instead of TYutaniParticleEngine we host a TYutaniPathTracer and we feed
  it the same scene NarcisDR ships in his C++ sample (scene.obj + dragon.obj
  + glass + metal + an area light + HDRI sky).

  This file is intentionally a near-clone of uParticleEngine.pas so you can
  diff the two and see exactly what changed when migrating a Yutani wrapper
  from the particle engine to the path tracer.

  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit PathTracingSample;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math, System.SyncObjs,
  Winapi.Windows, Winapi.MMSystem, Vcl.Controls, Raylib, rlgl, RayMath,
  Yutani.Render.PathTracing;

const
  SPIN_THRESHOLD_NS = 2000000; // 2 ms threshold for spin-waiting

type
  // High-resolution timer using QueryPerformanceCounter (QPC)
  // Identical to the uParticleEngine.pas implementation. Kept verbatim
  // because the frame-pacing core is "excellent, stable and fast" - we
  // don't touch what works.
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  TPathTracingSample = class(TThread)
  private
    FParentHandle: HWND;
    FRaylibWnd: HWND;
    FTargetFPS: Integer;
    FRealFPS: Integer;
    FActive: Boolean;
    FWidth, FHeight: Integer;

    // Our path tracer instance - replaces FParticles from the particle wrapper
    FPathTracer: TYutaniPathTracer;

    // Path tracer data containers (CPU side - the GPU buffers live inside FPathTracer)
    FData: PTData;
    FParams: PTParams;
    FScreen: PTScreen;
    FCamera: PTCam;

    // A plain Raylib Camera3D is kept in sync so we can still use Raylib's
    // 3D drawing helpers (DrawGrid, debug overlays) for the viewport preview.
    FCamera3D: TCamera3D;

    // Scene-bound materials. These are record values (PTMaterial is a record,
    // not a pointer), so no New/Dispose - they live inline as fields of Self.
    FMatDiffuseWhite: PTMaterial;
    FMatRedGlossy:    PTMaterial;
    FMatMetal:        PTMaterial;
    FMatGlass:        PTMaterial;
    FMatPurpleGlass:  PTMaterial;
    FMatEmissiveWhite: PTMaterial;

    // True once the OpenGL context is ready and InitCompute has succeeded
    FGLReady: Boolean;

    procedure RenderScene;
    procedure SetActive(const Value: Boolean);

    // One-time scene construction: initializes materials, imports all OBJ files,
    // creates the area light, builds the BVH, uploads everything to the GPU.
    procedure BuildScene;

    // One-time params/camera defaults (mirrors the C++ initializers)
    procedure InitParams;
    procedure InitCamera;

    // Per-frame non-render work: handle camera input, update camera matrices,
    // advance the sample counter
    procedure UpdateState(const DeltaSec: Double);

    // Convenience: convert PTCam matrices into a Raylib Camera3D for any 3D
    // helper drawing we still want to do
    procedure SyncCamera3D;
  protected
    procedure Execute; override;
  public
    constructor Create(AParentHandle: HWND);
    destructor Destroy; override;

    procedure StartEngine;
    procedure StopEngine;

    procedure SetFPS(const FPS: Integer);
    procedure SetDimensions(const W, H: Integer);

    // External Triggers - kept the same names as the particle wrapper so the
    // existing VCL form can call them unchanged.
    procedure TriggerRebuildScene;
    procedure TriggerResetSamples;
    procedure TriggerDofClick;

    property RealFPS: Integer read FRealFPS;
    property TargetFPS: Integer read FTargetFPS;
    property Active: Boolean read FActive write SetActive;
  end;

implementation

{ THighResTimer }

procedure THighResTimer.Init;
begin
  if not QueryPerformanceFrequency(Frequency) then
    Frequency := 0;
end;

function THighResTimer.GetTicks: Int64;
begin
  QueryPerformanceCounter(Result);
end;

// Hybrid sleep strategy: Sleep(1) for long waits, SpinWait for short waits
// This prevents thread context switching overhead while maintaining high precision.
procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  SpinTicks, Remaining: Int64;
begin
  if Frequency = 0 then
    Exit;
  SpinTicks := (ASpinNanoseconds * Frequency) div 1000000000;

  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;

  // Spin-wait the remaining time for exact frame pacing
  while GetTicks < ATargetTicks do
    ;
end;

{ TPathTracingSample }

constructor TPathTracingSample.Create(AParentHandle: HWND);
begin
  inherited Create(True); // Create suspended
  FreeOnTerminate := False;
  FParentHandle := AParentHandle;
  FTargetFPS := 60;
  FActive := False;
  FWidth := 1280;
  FHeight := 720;

  // DO NOT create FPathTracer here! OpenGL context is not ready yet.
  FPathTracer := nil;
  FGLReady    := False;

  // Initialize empty data containers - they will be filled in BuildScene
  FillChar(FData,   SizeOf(PTData),   0);
  FillChar(FParams, SizeOf(PTParams), 0);
  FillChar(FScreen, SizeOf(PTScreen), 0);
  FillChar(FCamera, SizeOf(PTCam),    0);

  // Material fields are records - nothing to allocate, they live inline.
  // FillChar above already zeroed FParams (which contains rmMat).
  // Zero out the standalone material records too so their initial state
  // is well-defined before BuildScene assigns real values.
  FillChar(FMatDiffuseWhite,  SizeOf(PTMaterial), 0);
  FillChar(FMatRedGlossy,     SizeOf(PTMaterial), 0);
  FillChar(FMatMetal,         SizeOf(PTMaterial), 0);
  FillChar(FMatGlass,         SizeOf(PTMaterial), 0);
  FillChar(FMatPurpleGlass,   SizeOf(PTMaterial), 0);
  FillChar(FMatEmissiveWhite, SizeOf(PTMaterial), 0);
end;

destructor TPathTracingSample.Destroy;
var
  i: Integer;
begin
  StopEngine;

  // Free the path tracer if it was created in Execute
  FreeAndNil(FPathTracer);

  // Materials are record values - nothing to dispose, they live inline in Self.
  // AreaLight.areaLightMat is also a record value, same story.

  // Free all PTModel instances owned by the scene (these ARE classes)
  for i := 0 to High(FData.models) do
    FData.models[i].Free;
  SetLength(FData.models, 0);

  inherited;
end;

procedure TPathTracingSample.SetDimensions(const W, H: Integer);
begin
  FWidth := W;
  FHeight := H;
  if FRaylibWnd <> 0 then
    SetWindowPos(FRaylibWnd, 0, 0, 0, FWidth, FHeight, SWP_NOZORDER or SWP_NOACTIVATE);
end;

procedure TPathTracingSample.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if Suspended then
        Start;
    end;
  end;
end;

procedure TPathTracingSample.StartEngine;
begin
  Active := True;
end;

procedure TPathTracingSample.StopEngine;
begin
  Active := False;
end;

procedure TPathTracingSample.SetFPS(const FPS: Integer);
begin
  if FTargetFPS <> FPS then
    FTargetFPS := FPS;
end;

{------------------------------------------------------------------------------*
 *  Scene initialization
 *-----------------------------------------------------------------------------}
procedure TPathTracingSample.InitParams;
begin
  // Mirrors the C++ Params struct default initializer
  FParams.screenSize := Vector2Create(FWidth, FHeight);
  FParams.dt         := 0.0;
  FParams.res        := 512;

  FParams.maxBounces     := 5;
  FParams.prevMaxBounces := FParams.maxBounces;
  FParams.maxSamples     := 50000;
  FParams.raysPerPixel   := 1;
  FParams.currentSample  := 0;

  FParams.enableSky    := True;
  FParams.enableHDRI   := True;
  FParams.skyIntensity := 1.0;
  FParams.blur         := 1.0;
  FParams.exposure     := 1.0;
  FParams.contrast     := 0.8;
  FParams.hdriThreshold := 0.0;
  FParams.hdriBrigthest := 0.0;
  FParams.hdriRotation  := 0.0;

  FParams.enableSun    := False;
  FParams.sunDir       := Vector3Create(0.0, 0.0, 1.0);
  FParams.sunColor     := Vector3Create(1.0, 1.0, 0.95);
  FParams.sunIntensity := 100.0;
  FParams.sunAngle     := 7.53;

  FParams.skyTopOriginal  := Vector3Create(0.263, 0.553, 0.769);
  FParams.skyBaseOriginal := Vector3Create(0.89,  0.824, 0.698);
  FParams.skyTop  := FParams.skyTopOriginal;
  FParams.skyBase := FParams.skyBaseOriginal;

  FParams.refractiveAmount := 0;

  FParams.totalMs    := 0.0;
  FParams.totalFrames:= 0;

  FParams.shouldSample   := True;
  FParams.enableSampling := True;

  FParams.isMouseHoveringUI := False;
  FParams.enableDebugRay    := False;
  FParams.enableSelection   := True;
  FParams.render            := True;

  FParams.enableCaustics     := True;
  FParams.enableBiasCaustics := False;
  FParams.causticsIntensity  := 1.0;
  FParams.biasCausticsContactClamp := 0.1;
  FParams.mainBufferIntensity := 1.0;
  FParams.renderTime := 0.0;

  // PBR-only mode (we deliberately disable the experimental ray marcher)
  FParams.rayMarcher := False;
  FParams.pathTracer := True;

  // Ray-marcher params kept for parity but unused when rayMarcher = False
  FParams.rmMaxSteps        := 350;
  FParams.rmNearPlane       := 0.001;
  FParams.rmFarPlane        := 1000.0;
  FParams.rmNormalPrecision := 0.001;
  FParams.rmLodAmount       := 0.0;
  FParams.rmLodMinDistMult  := 100.0;
  FParams.rmPBR             := False;

  // Build the default ray-marcher material (matches the C++ initializer).
  // rmMat is a record field, so we just assign fields directly - no New().
  FParams.rmMat.albedo            := Vector3Create(0.7, 0.7, 0.7);
  FParams.rmMat.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FParams.rmMat.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FParams.rmMat.absorptionCol     := Vector3Create(1.0, 1.0, 1.0);
  FParams.rmMat.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FParams.rmMat.IOR               := 1.5;
  FParams.rmMat.roughness         := 1.0;
  FParams.rmMat.emissionIntensity := 0.0;
  FParams.rmMat.refraction        := 0.0;
  FParams.rmMat.absorption        := 0.0;
  FParams.rmMat.volume            := 0.0;
  FParams.rmMat.density           := 0.0;
  FParams.rmMat.metalness         := 0.0;

  FillChar(FParams.rmMatGPU, SizeOf(PTMaterialGPU), 0);

  FParams.enableGPU    := True;
  FParams.exportRender := False;

  FParams.hasSceneChanged := False;
  FParams.updateGPU       := False;
  FParams.updateCPU       := False;

  FParams.addAreaLight := False;

  FParams.selectedModelsAmount := 0;
end;

procedure TPathTracingSample.InitCamera;
begin
  // 1:1 with the C++ PTCam initializers
  FCamera.camPos    := Vector3Create(0.0, -16.0, 1.7);
  FCamera.camTarget := Vector3Create(0.0,  0.0, 1.7);

  FCamera.targetDist := 1.0;
  FCamera.camSpeed   := 10.0;
  FCamera.fov        := 45.0;

  FCamera.focalLengthMM := 35.0;
  FCamera.focalLength   := FCamera.focalLengthMM / 1000.0;
  FCamera.aperture      := 0.0;
  FCamera.fStop         := 2.0;
  FCamera.ISO           := 1.0;
  FCamera.focusDist     := 16.0;
  FCamera.sensorSize    := 35.0;

  FCamera.clickDof := False;

  FCamera.camNormal  := Vector3Create(0.0, 1.0, 0.0);
  FCamera.worldUp    := Vector3Create(0.0, 0.0, 1.0);
  FCamera.right      := Vector3Normalize(Vector3CrossProduct(FCamera.camNormal, FCamera.worldUp));
  FCamera.up         := Vector3Normalize(Vector3CrossProduct(FCamera.right, FCamera.camNormal));
  FCamera.halfFovRadians := DegToRad(FCamera.fov) * 0.5;
  // Use System.Math.Tan explicitly to avoid any name clash with Raylib helpers
  FCamera.verticalScale  := Single(System.Math.Tan(FCamera.halfFovRadians));

  FCamera.targetNormal := Vector3Create(0.0, 1.0, 0.0);

  FCamera.mouseSensitivity := 0.01;

  // Plain Raylib camera - kept in sync for any 3D drawing helpers
  FCamera3D.position   := Vector3Create(FCamera.camPos.x, FCamera.camPos.y, FCamera.camPos.z);
  FCamera3D.target     := Vector3Create(FCamera.camTarget.x, FCamera.camTarget.y, FCamera.camTarget.z);
  FCamera3D.up         := Vector3Create(FCamera.up.x, FCamera.up.y, FCamera.up.z);
  FCamera3D.fovy       := FCamera.fov;
  FCamera3D.projection := CAMERA_PERSPECTIVE;
end;

procedure TPathTracingSample.BuildScene;
var
  XareaLight: AreaLight;
  bvhArray: TCompactBVHGPUArray;
begin
  // Initialize all materials. These are record fields of Self - no allocation
  // needed, just assign fields directly. The OBJ importer takes them by const
  // reference and copies the record into each Tri it creates.
  FMatDiffuseWhite.albedo            := Vector3Create(0.7, 0.7, 0.7);
  FMatDiffuseWhite.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatDiffuseWhite.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatDiffuseWhite.absorptionCol     := Vector3Create(1.0, 1.0, 1.0);
  FMatDiffuseWhite.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatDiffuseWhite.IOR               := 1.5;
  FMatDiffuseWhite.roughness         := 1.0;
  FMatDiffuseWhite.emissionIntensity := 0.0;
  FMatDiffuseWhite.refraction        := 0.0;
  FMatDiffuseWhite.absorption        := 0.0;
  FMatDiffuseWhite.volume            := 0.0;
  FMatDiffuseWhite.density           := 0.0;
  FMatDiffuseWhite.metalness         := 0.0;

  FMatRedGlossy.albedo            := Vector3Create(0.7, 0.0, 0.0);
  FMatRedGlossy.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatRedGlossy.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatRedGlossy.absorptionCol     := Vector3Create(1.0, 1.0, 1.0);
  FMatRedGlossy.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatRedGlossy.IOR               := 1.5;
  FMatRedGlossy.roughness         := 0.15;
  FMatRedGlossy.emissionIntensity := 0.0;
  FMatRedGlossy.refraction        := 0.0;
  FMatRedGlossy.absorption        := 0.0;
  FMatRedGlossy.volume            := 0.0;
  FMatRedGlossy.density           := 0.0;
  FMatRedGlossy.metalness         := 1.0;

  FMatMetal.albedo            := Vector3Create(0.9, 0.9, 0.9);
  FMatMetal.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatMetal.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatMetal.absorptionCol     := Vector3Create(1.0, 1.0, 1.0);
  FMatMetal.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatMetal.IOR               := 1.5;
  FMatMetal.roughness         := 0.0;
  FMatMetal.emissionIntensity := 0.0;
  FMatMetal.refraction        := 0.0;
  FMatMetal.absorption        := 0.0;
  FMatMetal.volume            := 0.0;
  FMatMetal.density           := 0.0;
  FMatMetal.metalness         := 1.0;

  FMatGlass.albedo            := Vector3Create(1.0, 1.0, 1.0);
  FMatGlass.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatGlass.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatGlass.absorptionCol     := Vector3Create(1.0, 1.0, 1.0);
  FMatGlass.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatGlass.IOR               := 1.5;
  FMatGlass.roughness         := 0.0;
  FMatGlass.emissionIntensity := 0.0;
  FMatGlass.refraction        := 1.0;
  FMatGlass.absorption        := 0.0;
  FMatGlass.volume            := 0.0;
  FMatGlass.density           := 15.0;
  FMatGlass.metalness         := 0.0;

  FMatPurpleGlass.albedo            := Vector3Create(1.0, 1.0, 1.0);
  FMatPurpleGlass.specularCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatPurpleGlass.emissionCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatPurpleGlass.absorptionCol     := Vector3Create(0.5, 0.6, 0.0);
  FMatPurpleGlass.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatPurpleGlass.IOR               := 1.5;
  FMatPurpleGlass.roughness         := 0.0;
  FMatPurpleGlass.emissionIntensity := 0.0;
  FMatPurpleGlass.refraction        := 1.0;
  FMatPurpleGlass.absorption        := 1.0;
  FMatPurpleGlass.volume            := 0.0;
  FMatPurpleGlass.density           := 15.0;
  FMatPurpleGlass.metalness         := 0.0;

  FMatEmissiveWhite.albedo            := Vector3Create(0.0, 0.0, 0.0);
  FMatEmissiveWhite.specularCol       := Vector3Create(0.0, 0.0, 0.0);
  FMatEmissiveWhite.emissionCol       := Vector3Create(1.0, 1.0, 1.0);
  FMatEmissiveWhite.absorptionCol     := Vector3Create(0.0, 0.0, 0.0);
  FMatEmissiveWhite.volumeCol         := Vector3Create(0.0, 0.0, 0.0);
  FMatEmissiveWhite.IOR               := 1.0;
  FMatEmissiveWhite.roughness         := 1.0;
  FMatEmissiveWhite.emissionIntensity := 10.0;
  FMatEmissiveWhite.refraction        := 0.0;
  FMatEmissiveWhite.absorption        := 0.0;
  FMatEmissiveWhite.volume            := 0.0;
  FMatEmissiveWhite.density           := 0.0;
  FMatEmissiveWhite.metalness         := 0.0;

  // Import all OBJ files. The "false" / "true" doubleSided flag is preserved
  // from the C++ sample: scene.obj is single-sided, all others double-sided
  // so the glass / metal / dragon don't disappear when viewed from inside.
  TObjImporter.Load('models/scene.obj',       FData, FMatDiffuseWhite, False);
  TObjImporter.Load('models/sceneGlass.obj',  FData, FMatGlass,        True);
  TObjImporter.Load('models/sceneMetal.obj',  FData, FMatMetal,        True);
  TObjImporter.Load('models/sceneRed.obj',    FData, FMatRedGlossy,    True);
  TObjImporter.Load('models/dragon.obj',      FData, FMatPurpleGlass,  True);

  // Add a single emissive area light above the scene (matches the C++ sample)
  InitAreaLight(XareaLight,
                Vector3Create(0.0, 0.0, 3.0),
                Vector3Create(1.0, 1.0, 1.0),
                10.0, 1.0,
                FData);
  SetLength(FData.areaLights, Length(FData.areaLights) + 1);
  FData.areaLights[High(FData.areaLights)] := XareaLight;

  // Initialize the screen + buffer dimensions
  FScreen.InitScreen(FParams.res, FData);

  // Build the flat BVH (this also reorders tris to match BVH leaf order)
  FPathTracer.CreateFlatBVH(FData);

  // Upload triangles to GPU
  FPathTracer.UploadTriangles(FData);
  FPathTracer.InitTriangleSSBO(FData.trisGPU);

  // Upload flattened BVH to GPU. The engine exposes a copy-method because
  // Delphi can't have dynamic-array properties.
  bvhArray := FPathTracer.GetGlobalCompactBVHGPUCopy;
  FPathTracer.InitBVHSSBO(bvhArray);

  // Load HDRI for sky lighting
  FParams.hdri := LoadImage('textures/HDRI.hdr');
  ImageFormat(@FParams.hdri, PIXELFORMAT_UNCOMPRESSED_R32G32B32);
  FPathTracer.HdriBrightestValue(FParams.hdri, FParams.hdriBrigthest);
  FPathTracer.LoadHDRI(FParams);

  // Initialize compute shader + textures + UBOs
  FPathTracer.InitCompute(FScreen.resX, FScreen.resY, 'shaders/ptShader.comp');
  FGLReady := True;
end;

{------------------------------------------------------------------------------*
 *  Per-frame state update (camera + sample counter)
 *-----------------------------------------------------------------------------}
procedure TPathTracingSample.SyncCamera3D;
begin
  FCamera3D.position   := Vector3Create(FCamera.camPos.x,    FCamera.camPos.y,    FCamera.camPos.z);
  FCamera3D.target     := Vector3Create(FCamera.camTarget.x, FCamera.camTarget.y, FCamera.camTarget.z);
  FCamera3D.up         := Vector3Create(FCamera.up.x,        FCamera.up.y,        FCamera.up.z);
  FCamera3D.fovy       := FCamera.fovV;
  FCamera3D.projection := CAMERA_PERSPECTIVE;
end;

procedure TPathTracingSample.UpdateState(const DeltaSec: Double);
var
  ratio: Single;
begin
  // Clamp dt to avoid huge camera jumps on lag spikes (mirrors the C++ behaviour)
  if (DeltaSec <= 0) or (DeltaSec > 0.25) then
    FParams.dt := 1 / 60
  else
    FParams.dt := DeltaSec;

  FParams.totalMs   := FParams.totalMs + FParams.dt * 1000.0;
  FParams.totalFrames := FParams.totalFrames + 1;

  // Drive the camera (this also resumes sampling when no input is held)
  ratio := FScreen.ratio;
  FCamera.CameraLogic(FParams, ratio);
  FScreen.ratio := ratio;

  // Make sure the params struct reflects the current viewport size so the
  // camera logic + sample gate see consistent values
  FParams.screenSize := Vector2Create(FWidth, FHeight);

  // Any change to the scene invalidates the accumulation buffer
  if FParams.hasSceneChanged then
  begin
    FParams.updateGPU := True;
    FParams.updateCPU := True;
  end;

  if (FParams.updateGPU) and FGLReady then
  begin
    FPathTracer.CreateFlatBVH(FData);
    FPathTracer.UploadTriangles(FData);
    FPathTracer.UploadBVH;
    FParams.updateGPU := False;
  end;

  if FParams.updateCPU then
    FParams.updateCPU := False;

  SyncCamera3D;
end;

{------------------------------------------------------------------------------*
 *  External Triggers (API matches uParticleEngine.pas so the VCL form is happy)
 *-----------------------------------------------------------------------------}
procedure TPathTracingSample.TriggerRebuildScene;
begin
  // Force a full BVH + GPU re-upload on the next frame
  FParams.hasSceneChanged := True;
  FParams.shouldSample    := False;
end;

procedure TPathTracingSample.TriggerResetSamples;
begin
  // Reset the accumulation buffer - the next dispatch will start from scratch
  FParams.shouldSample    := False;
  FParams.currentSample   := 1;
end;

procedure TPathTracingSample.TriggerDofClick;
begin
  // Enable click-to-focus DoF: the next left mouse click sets focusDist to
  // the distance of whatever triangle is under the cursor
  FCamera.clickDof := True;
end;

{------------------------------------------------------------------------------*
 *  Render
 *-----------------------------------------------------------------------------}
procedure TPathTracingSample.RenderScene;
var
  fpsStr, sampleStr: AnsiString;
begin
  BeginDrawing();
  ClearBackground(BLACK);

  // The path tracer dispatches its compute shader and draws the final image
  // as a full-screen quad. We do NOT call BeginMode3D here because the tracer
  // owns the screen for this frame.
  if FGLReady and FParams.render then
    FPathTracer.RunShader(Vector2Create(FWidth, FHeight),
                          FScreen.resX, FScreen.resY,
                          FCamera, FParams, FScreen);

  // HUD overlay - drawn on top of the GPU render
  fpsStr := AnsiString(Format('FPS: %d', [FRealFPS]));
  DrawText(PAnsiChar(fpsStr), 10, 10, 20, GREEN);

  if FGLReady then
  begin
    sampleStr := AnsiString(Format('Samples: %d / %d', [FParams.currentSample, FParams.maxSamples]));
    DrawText(PAnsiChar(sampleStr), 10, 40, 20, YELLOW);
    DrawText(PAnsiChar(AnsiString(Format('Bounces: %d  RPP: %d', [FParams.maxBounces, FParams.raysPerPixel]))),
             10, 70, 20, RAYWHITE);
    DrawText(PAnsiChar(AnsiString(Format('Tris: %d', [Length(FData.tris)]))),
             10, 100, 20, RAYWHITE);
  end
  else
  begin
    DrawText('Initializing GPU path tracer...', 10, 40, 20, YELLOW);
  end;

  EndDrawing();

  // Force VCL to update the parent control where Raylib is embedded
  if FRaylibWnd <> 0 then
    RedrawWindow(FRaylibWnd, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
end;

{------------------------------------------------------------------------------*
 *  Main thread loop
 *-----------------------------------------------------------------------------}
procedure TPathTracingSample.Execute;
var
  Timer: THighResTimer;
  Freq, FrameTicks: Int64;
  NextFrame, NowTicks, LastFrameTicks: Int64;
  DeltaSec: Double;
  FrameCount: Integer;
  LastFpsTime: Int64;
  WindowName: AnsiString;
begin
  // Increase Windows timer resolution for Sleep(1) accuracy
  {$IFDEF MSWINDOWS}
  timeBeginPeriod(1);
  {$ENDIF}
  try
    SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_WINDOW_ALWAYS_RUN);

    // Generate a unique window name to prevent handle collisions
    WindowName := AnsiString('PathTracingSample_' + IntToStr(IntPtr(Self)));
    InitWindow(FWidth, FHeight, PAnsiChar(WindowName));

    // Retrieve the newly created Raylib window handle and embed it into VCL
    FRaylibWnd := FindWindowA(nil, PAnsiChar(WindowName));
    if (FRaylibWnd <> 0) and (FParentHandle <> 0) then
    begin
      Winapi.Windows.SetParent(FRaylibWnd, FParentHandle);
      SetWindowLong(FRaylibWnd, GWL_STYLE, WS_CHILD or WS_VISIBLE);
      SetWindowPos(FRaylibWnd, 0, 0, 0, FWidth, FHeight, SWP_NOZORDER or SWP_NOACTIVATE);
    end;

    // CRITICAL FIX: Build the scene AFTER the OpenGL context is ready, so
    // that glGenBuffers / glTexStorage2D etc. don't fail silently. This
    // mirrors the original uParticleEngine.pas fix where the particle engine
    // was constructed inside Execute() rather than in the constructor.
    FPathTracer := TYutaniPathTracer.Create;

    // Reset the global IDs - in case the wrapper is restarted multiple times
    // we want fresh IDs for the new scene
    GlobalTriId   := 0;
    GlobalModelId := 0;

    InitParams;
    InitCamera;
    BuildScene;

    // Initialize frame pacing timers
    Timer.Init;
    Freq := Timer.Frequency;
    if Freq <= 0 then
      Freq := 10000000;

    NowTicks := Timer.GetTicks;
    LastFrameTicks := NowTicks;
    NextFrame := NowTicks;
    LastFpsTime := NowTicks;
    FrameCount := 0;

    // Main Raylib Loop - identical structure to uParticleEngine.pas
    while not Terminated do
    begin
      if WindowShouldClose() then
        Break;

      NowTicks := Timer.GetTicks;
      DeltaSec := (NowTicks - LastFrameTicks) / Freq;
      LastFrameTicks := NowTicks;

      // Clamp delta time to avoid physics tunnelling on lag spikes
      if (DeltaSec <= 0) or (DeltaSec > 0.25) then
        DeltaSec := 1 / 60;

      if FActive then
        UpdateState(DeltaSec);

      RenderScene;

      // Real FPS calculation
      Inc(FrameCount);
      if (NowTicks - LastFpsTime) >= Freq then
      begin
        FRealFPS := Round(FrameCount * Freq / (NowTicks - LastFpsTime));
        FrameCount := 0;
        LastFpsTime := NowTicks;
      end;

      // Calculate exact deadline for the next frame
      if FTargetFPS > 0 then
        FrameTicks := Round(Freq / FTargetFPS)
      else
        FrameTicks := Freq div 60;

      NextFrame := NextFrame + FrameTicks;

      // If we are falling behind, reset NextFrame to current time to prevent fast-catching
      NowTicks := Timer.GetTicks;
      if (NowTicks - NextFrame) > Freq then
        NextFrame := NowTicks;

      // Wait precisely until the next frame deadline
      Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
    end;

  finally
    // Free the engine BEFORE we close the window! (matches the original wrapper)
    FreeAndNil(FPathTracer);

    if FRaylibWnd <> 0 then
      CloseWindow();

    {$IFDEF MSWINDOWS}
    timeEndPeriod(1);
    {$ENDIF}
  end;
end;

end.

