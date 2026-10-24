# Yutani.Render.PathTracing
A 1:1 Object Pascal port of [NarcisCalin's N-Ray](https://github.com/NarcisCalin/N-Ray) C++ path tracing sample, reworked to fit the Yutani sandbox architecture. It runs the entire path tracer on the GPU via an OpenGL 4.3 compute shader   
          
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/Yutani.Render.PathTracing)    
        
<img width="963" height="497" alt="Unbenannt" src="https://github.com/user-attachments/assets/c5f169f6-9705-4d7c-8767-0c52ff8dcb5a" />
ok 12fps sounds not fast but thats on ryzen4500u igpu :P (my rtx2060s is doing around 120fps)     
    
    This is **not** a CPU path tracer. There's no Embree binding, no software BVH traversal on the CPU, no fallback. The GLSL compute shader (`shaders/ptShader.comp`) is byte-for-byte identical to the upstream original — Delphi just feeds it data and pulls pixels back.   
    
## Features     
    
- **GPU-only rendering** via OpenGL 4.3 compute shader, dispatched in 16×16 workgroups    
- **Full PBR path tracing** — diffuse (cosine hemisphere), GGX microfacet specular, refraction with Beer-Lambert absorption and colored tint   
- **Custom flat-BVH** built in pure Object Pascal, with avg-split heuristics matching the upstream C++. Flattens into a `std430`-friendly `CompactBVHGPU` array streamed straight into a shader storage buffer — no acceleration library needed    
- **PTCam** ported as a Delphi record with the full upstream camera model: aperture, ISO, sensor size, focal length, focus distance, dynamic DoF click    
- **HDRI / procedural sky / sun** lighting with HDRI rotation, threshold, and brightest-value scan    
- **Caustics buffer** for refractive light transport (separate accumulation buffer, mixed at final blit)    
- **Volumetric scattering** for participating media    
- **Emissive triangles** as direct light sources (AreaLight helper included)    
- **Multi-sample accumulation** with auto-pause on camera input and auto-resume when idle    
- **QPC frame pacing** with hybrid `Sleep(1)` + spin-wait — same excellent, stable, fast core as the Yutani particle engine wrapper    
- **VCL window embedding** via `SetParent` so the raylib window lives inside a `TPanel`    
    
## Controls    
     
Same as the C++ original — ported verbatim in `PTCam.CameraLogic`:   
    
| Input | Action |   
|-------|--------|    
| `W` `A` `S` `D` | Move camera on the horizontal plane |   
| `Left Shift` / `Left Ctrl` | Move camera up / down |   
| `Right Mouse Drag` | Look around (with edge-wrap cursor teleport, like an FPS) |   
| `Right Mouse + Wheel` | Adjust camera speed |   
   
While any movement key or mouse button is held, sampling auto-pauses so the viewport stays responsive. When input is released, accumulation resumes.   
    
## Performance notes    
    
On an AMD Ryzen 5 4500U integrated GPU, the sample scene renders at **~12 FPS** with continuous accumulation (188k triangles, 5 bounces, 1 ray per pixel). The bottleneck is purely the compute dispatch — the Delphi-side overhead is negligible (BVH build for 188k tris takes ~150 ms, after that each frame is just uniform uploads + dispatch + blit).   
    
To scale performance:    
    
- **Lower `maxBounces`** from 5 to 3 — saves ~40% with minimal visual difference
- **Lower `params.res`** from 512 to 384 — compute load scales quadratically
- **Use a discrete GPU** — an RTX-class card easily hits 60+ FPS at full resolution
    
## Credits     
     
This is a port of **[NarcisCalin's N-Ray](https://github.com/NarcisCalin/N-Ray)** — a beautiful, well-structured C++ path tracing sample built on raylib. All of the actual rendering math (BVH traversal, GGX sampling, Beer-Lambert absorption, caustics, ray marching SDFs, HDRI sampling, the entire compute shader) is his work. The Delphi port just wraps and feeds it.     
     
- **Original author:** [NarcisCalin](https://github.com/NarcisCalin)
- **Original repo:** [N-Ray](https://github.com/NarcisCalin/N-Ray)
    

