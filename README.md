## Overview
A render graph implemented in Odin with direct d3d12 bindings. 

```rg``` contains the render graph implementation. 

```d3d12ma``` is a wrapper for the C++ library. ```dxc_compile``` is a light-weight package to invoke dxc to compile ray-tracing (SM6) shaders. Both packages can be used as libraries independently.

```gltf``` and ```rtsample``` are packages to demo the render graph. Might combine them in the future since they are coupled quite hard now. 

Largely a research/study project. 

## Render Graph
Currently the rg performs a topological sort of declared nodes, automatically creates resource descriptors based on declared read/writes, and invokes init and execute callbacks of render pass nodes. 
Immediate WIP is to automatically insert fences between passes.

## DLLs
Requires ```dxil.dll``` ```dxcompiler.dll``` ```SDL3.dll```. 

## Usage 
```
cd build
# dlls should be here
odin run ../rtsample
```
