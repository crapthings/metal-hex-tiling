# Contributing

Issues and pull requests are welcome.

## Before submitting

1. Run `swift test` on a Metal-capable macOS machine.
2. Run the sibling `macos-metal-001` GPU verification when changing MSL behavior.
3. Keep the library target independent of AppKit and MetalKit.
4. Document visible, ABI, performance, or color-space changes.

Shader changes should be checked with representative base-color and data maps. Include GPU model, OS version, screenshots, and timing information when reporting rendering or performance regressions.
