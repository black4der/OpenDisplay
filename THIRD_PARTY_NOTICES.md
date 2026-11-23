# Third-party notices

The full OpenDisplay app links the following third-party code. The public-API-only flavor does not.

## d65 (white-point calibration with an iPhone probe)

https://github.com/Tinnci/d65, pinned in `project.yml`. Linked as Swift packages (D65Core, D65Display,
D65Calibration, D65Link, D65Host, D65MacRuntime). `Apps/OpenDisplay/Sources/WhitePointCalibration.swift`
also adapts the probe listener from d65's `Sources/D65MacRuntime/NetworkTransport.swift`.

```
MIT License

Copyright (c) 2026 Tinnci

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### CIE datasets bundled by d65

D65Core bundles CIE colour-matching functions and the CIE standard illuminant D65, unchanged, under
**CC BY-SA 4.0** (https://creativecommons.org/licenses/by-sa/4.0/). Attribution: CIE (2019),
Colour-matching functions of CIE 1931 standard colorimetric observer (ISO/CIE 11664-1:2019); CIE (2015),
CIE cone-fundamental-based spectral tristimulus values for 2° and 10° field size; CIE (2019), CIE
standard illuminant D65; International Commission on Illumination (CIE), Vienna, AT.

### MonitorControl (via d65)

d65's `D65Display` ports MonitorControl's `Arm64DDC` packet layout and uses the same `IOAVService` entry
points (https://github.com/MonitorControl/MonitorControl). OpenDisplay does not call that DDC code — its
own DDC layer drives monitors — but the module is linked because d65's calibration engine depends on it.

```
MIT License

Copyright © 2017

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle

https://github.com/sparkle-project/Sparkle — in-app updates, under its own license (MIT-style), shipped
inside `Sparkle.framework`.
