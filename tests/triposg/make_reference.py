"""Reference outputs from VAST-AI's own TripoSG, for the Swift port to be
checked against: scripts/run-triposg-parity.sh.

Needs a checkout of github.com/VAST-AI-Research/TripoSG, its weights
(huggingface.co/VAST-AI/TripoSG) and a Python with torch, diffusers 0.32,
transformers 4.48 and PyMCubes. Nothing here ships; run it in a scratch
environment and delete the environment afterwards.

    python make_reference.py <TripoSG checkout> <weights dir> <cut-out RGBA png> <out dir> [steps]

Runs in float32 on the GPU (MPS). Writes little-endian float32 files:
  pixels.bin      (3, 224, 224)  what DINOv2 sees, normalised
  embeds.bin      (257, 1024)    DINOv2-large's last hidden state
  noise0.bin      (2048, 64)     the starting latents
  sigmas.bin      (steps + 1,)   the scheduler's sigmas
  velocity0.bin   (2048, 64)     the first step's guided prediction
  latents.bin     (2048, 64)     the latents after every step
  probe.bin, velocity_probe0.bin, velocity_probe1.bin
                                 guided velocities at sigma 0.55 and 0.05 for
                                 half the starting noise
  kv.bin          (2048, 1024)   the decoder's self-attended latents
  points.bin      (4096, 3)      query points in [-1, 1]
  logits.bin      (4096,)        the decoder's logits there (positive outside)
and meta.json with the step count and guidance.
"""
import json, os, sys, types
import numpy as np, torch
from PIL import Image

repo, weights, cutout, out = sys.argv[1:5]
steps = int(sys.argv[5]) if len(sys.argv) > 5 else 20
guidance = 7.0
sys.path.insert(0, repo)
sys.modules.setdefault("diso", types.SimpleNamespace(DiffDMC=None))
from triposg.pipelines.pipeline_triposg import TripoSGPipeline

os.makedirs(out, exist_ok=True)
dev = "mps" if torch.backends.mps.is_available() else "cpu"
pipe = TripoSGPipeline.from_pretrained(weights).to(dev, torch.float32)

def save(name, t):
    np.ascontiguousarray(t.detach().float().cpu().numpy() if torch.is_tensor(t) else t, dtype="<f4").tofile(os.path.join(out, name))

# TripoSG's preparation with a given alpha: white background, crop, 10% padding, square.
a = np.array(Image.open(cutout).convert("RGBA")).astype(np.float32) / 255
alpha = a[..., 3:4]
rgb = a[..., :3] * alpha + (1 - alpha)
ys, xs = np.nonzero(alpha[..., 0] > 0)
crop = rgb[ys.min():ys.max() + 1, xs.min():xs.max() + 1]; h, w = crop.shape[:2]
if w > h:
    px = int(w * 0.1); py = int(px + (w - h) / 2)
else:
    py = int(h * 0.1); px = int(py + (h - w) / 2)
image = Image.fromarray((np.pad(crop, ((py, py), (px, px), (0, 0)), constant_values=1.0) * 255).astype(np.uint8))

with torch.no_grad():
    pixels = pipe.feature_extractor_dinov2(image, return_tensors="pt").pixel_values.to(dev)
    save("pixels.bin", pixels[0])
    embeds = pipe.image_encoder_dinov2(pixels).last_hidden_state
    save("embeds.bin", embeds[0])
    both = torch.cat([torch.zeros_like(embeds), embeds], 0)
    g = torch.Generator().manual_seed(1234)
    latents = torch.randn((1, 2048, 64), generator=g).to(dev)
    save("noise0.bin", latents[0])
    pipe.scheduler.set_timesteps(steps, device=dev)
    save("sigmas.bin", pipe.scheduler.sigmas)
    for i, t in enumerate(pipe.scheduler.timesteps):
        pred = pipe.transformer(torch.cat([latents] * 2), t.expand(2), encoder_hidden_states=both, return_dict=False)[0]
        u, c = pred.chunk(2)
        pred = u + guidance * (c - u)
        if i == 0:
            save("velocity0.bin", pred[0])
        latents = pipe.scheduler.step(pred, t, latents, return_dict=False)[0]
    save("latents.bin", latents[0])
    # The guided velocity at later sigmas for fixed latents: a timestep bug
    # shows here, where the whole trajectory's drift would hide it.
    probe = torch.from_numpy(np.fromfile(os.path.join(out, "noise0.bin"), dtype="<f4").reshape(1, 2048, 64)).to(dev) * 0.5
    save("probe.bin", probe[0])
    for i, sigma in enumerate((0.55, 0.05)):
        t = torch.tensor([sigma * 1000.0], device=dev)
        pred = pipe.transformer(torch.cat([probe] * 2), t.expand(2), encoder_hidden_states=both, return_dict=False)[0]
        u, c = pred.chunk(2)
        save(f"velocity_probe{i}.bin", (u + guidance * (c - u))[0])
    vae = pipe.vae
    z = vae.post_quant(latents)
    kv = z
    for block in vae.decoder.blocks[:-1]:
        kv = block(kv)
    save("kv.bin", kv[0])
    pts = (torch.rand(4096, 3, generator=torch.Generator().manual_seed(7)) * 2 - 1) * 0.9
    save("points.bin", pts)
    logits, _ = vae.decoder(z, vae.embedder(pts[None].to(dev)), kv)
    save("logits.bin", logits[0, :, 0])
json.dump({"steps": steps, "guidance": guidance}, open(os.path.join(out, "meta.json"), "w"))
print("reference written to", out)
