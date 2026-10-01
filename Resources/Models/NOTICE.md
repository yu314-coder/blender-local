# Models used by Image to 3D Model

## Depth Anything V2 Small — bundled

`DepthAnythingV2SmallF16.mlpackage`, the Core ML conversion Apple publishes at
huggingface.co/apple/coreml-depth-anything-v2-small, of Depth Anything V2 by
Lihe Yang, Bingyi Kang, Zilong Huang, Zhen Zhao, Xiaogang Xu, Jiashi Feng and
Hengshuang Zhao ("Depth Anything V2", arXiv:2406.09414).

Licensed under the Apache License, Version 2.0. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by
applicable law or agreed to in writing, software distributed under the License
is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied.

## TripoSG — downloaded on request, not bundled

The Full 3D mode downloads the weights VAST AI publishes at
huggingface.co/VAST-AI/TripoSG when asked, converts them to a smaller number
format on the device, and runs them with Blender Local's own Metal
implementation of the network described at
github.com/VAST-AI-Research/TripoSG ("TripoSG: High-Fidelity 3D Shape Synthesis
using Large-Scale Rectified Flow Models").

TripoSG: Copyright (c) 2025 VAST-AI-Research and contributors. MIT License.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions: The above copyright notice and this
permission notice shall be included in all copies or substantial portions of the
Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED.

TripoSG's image encoder is DINOv2-large (facebook/dinov2-large) by Maxime
Oquab et al. ("DINOv2: Learning Robust Visual Features without Supervision",
arXiv:2304.07193), Copyright (c) Meta Platforms, Inc. and affiliates, licensed
under the Apache License, Version 2.0 (see above).
