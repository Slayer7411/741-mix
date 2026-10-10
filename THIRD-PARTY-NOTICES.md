# ◆ THIRD-PARTY NOTICES

MINOS-741 is licensed under GPL-2.0-or-later ([LICENSE.md](LICENSE.md)). it contains the following third-party code.
this file ships inside the app bundle (`Contents/Resources/THIRD-PARTY-NOTICES.md`).

| component | version | license | location |
|---|---|---|---|
| VST 3 SDK (hosting part) | 3.8.1 build 84 | MIT | `Sources/VST3SDK` |
| link library | 3.1.5 | GPL-2.0-or-later | `Sources/LinkKit` -> `LICENSE-Link.md` |
| signalsmith-stretch | 1.4.0 | MIT | `Sources/MixDSP/vendor/signalsmith-stretch` |
| signalsmith-linear | 146b26f | MIT | `Sources/MixDSP/vendor/signalsmith-linear` |
| cinzel, ibm plex mono | – | SIL open font license 1.1 | `Sources/MixApp/Resources/Fonts` |

## ◆ VST 3 SDK

VST is a registered trademark of Steinberg Media Technologies GmbH.

MINOS-741 uses the hosting part of the VST 3 SDK (interfaces, module loader, host classes) to load VST3 effect plugins.
it is not affiliated with or endorsed by Steinberg. source: https://github.com/steinbergmedia/vst3sdk (tag `v3.8.1_build_84`).

```
MIT License

Copyright (c) 2026, Steinberg Media Technologies GmbH

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

## ◆ SIGNALSMITH-STRETCH

```
MIT License

Copyright (c) 2022 Geraint Luff / Signalsmith Audio Ltd.

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

## ◆ SIGNALSMITH-LINEAR

```
MIT License

Copyright (c) 2025 Signalsmith Audio

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

## ◆ LINK LIBRARY

GPL-2.0-or-later, full text and copyright in `Sources/LinkKit/LICENSE-Link.md` and [LICENSE.md](LICENSE.md).

## ◆ FONTS

SIL open font license 1.1, full texts in `Sources/MixApp/Resources/Fonts/OFL-Cinzel.txt` and `OFL-IBMPlexMono.txt` (also inside the app bundle).
