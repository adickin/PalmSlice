# GNU Affero General Public License v3.0

Copyright (c) 2026 Adam Dickin

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

---

## Why AGPL-3.0?

This project embeds **libslic3r**, the core slicing library from
[OrcaSlicer](https://github.com/SoftFever/OrcaSlicer) (itself derived from
BambuStudio and [PrusaSlicer](https://github.com/prusa3d/PrusaSlicer)), and
OrcaSlicer's printer / filament profiles, all licensed under the GNU Affero
General Public License v3.0. As a derivative work, PalmSlice is required to
be distributed under the same license.

The AGPL-3.0 extends the GPL to cover network use: if you run a modified
version of this software as a service (even without distributing binaries),
you must make the modified source available to users of that service.

For the full license text see:
https://www.gnu.org/licenses/agpl-3.0.en.html

---

## Third-Party Licenses

| Library | License |
|---------|---------|
| [OrcaSlicer / libslic3r](https://github.com/SoftFever/OrcaSlicer) (from BambuStudio and PrusaSlicer), incl. its profiles | AGPL-3.0 |
| [PrusaSlicer](https://github.com/prusa3d/PrusaSlicer) Full Spectrum virtual extruders (ColorMix, ported into libslic3r) | AGPL-3.0 |
| [prusa_fdm_mixer](https://github.com/prusa3d/PrusaSlicer/tree/master/bundled_deps/prusa_fdm_mixer) (mix colour prediction) | MIT |
| [Boost](https://www.boost.org/) | Boost Software License 1.0 |
| [oneTBB](https://github.com/oneapi-src/oneTBB) | Apache-2.0 |
| [CGAL](https://www.cgal.org/) | GPL-3.0 / LGPL-3.0 (header-only parts: LGPL) |
| [GMP](https://gmplib.org/) | LGPL-3.0 |
| [MPFR](https://www.mpfr.org/) | LGPL-3.0 |
| [Eigen](https://eigen.tuxfamily.org/) | MPL-2.0 |
| [Clipper2](https://github.com/AngusJohnson/Clipper2) | Boost Software License 1.0 |
| [cereal](https://github.com/USCiLab/cereal) | BSD-3-Clause |
| [Qhull](http://www.qhull.org/) | Qhull license (permissive) |
| [MCUT](https://github.com/cutdigital/mcut) | GPL-3.0 (dual-licensed) |
| [libigl](https://libigl.github.io/) | MPL-2.0 |
| [libnoise](https://github.com/SoftFever/Orca-deps-libnoise) | LGPL-2.1 |
| [Draco](https://github.com/google/draco) | Apache-2.0 |
| [libjpeg-turbo](https://libjpeg-turbo.org/) | IJG / BSD-3-Clause / zlib |
| [nlohmann/json](https://github.com/nlohmann/json) | MIT |
| [NanoSVG](https://github.com/fltk/nanosvg) | zlib |
| [NLopt](https://github.com/stevengj/nlopt) | LGPL-2.1+ |
| [zlib](https://zlib.net/) | zlib |
| [libpng](http://www.libpng.org/) | libpng |
| [expat](https://libexpat.github.io/) | MIT |
