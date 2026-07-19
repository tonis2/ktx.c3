"""Smoke test for the libktx C API (src/capi) via ctypes.

Usage: python3 test/capi_smoke.py <path-to-ktx.so|ktx.dylib|ktx.dll>
Encodes a gradient to bc7-srgb / uastc / etc1s, decodes each back and checks
the error stays in codec-expected bounds. Run by CI after build-shared.sh.
"""
import ctypes
import sys

lib = ctypes.CDLL(sys.argv[1])
lib.ktx_encode.restype = ctypes.c_int
lib.ktx_encode.argtypes = [
    ctypes.c_char_p, ctypes.c_uint, ctypes.c_uint, ctypes.c_char_p,
    ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)), ctypes.POINTER(ctypes.c_size_t),
]
lib.ktx_decode.restype = ctypes.c_int
lib.ktx_decode.argtypes = [
    ctypes.c_char_p, ctypes.c_size_t,
    ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
    ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint),
]
lib.ktx_free.argtypes = [ctypes.c_void_p]
lib.ktx_last_error.restype = ctypes.c_char_p

W = H = 64
src = bytearray(W * H * 4)
for y in range(H):
    for x in range(W):
        i = (y * W + x) * 4
        src[i:i + 4] = ((x * 255) // (W - 1), (y * 255) // (H - 1), (x ^ y) & 0xFF, 255)
src = bytes(src)

failures = 0
for fmt, tol in (("rgba8-srgb", 0.0), ("bc7-srgb", 4.0), ("uastc", 4.0), ("etc1s", 16.0)):
    out = ctypes.POINTER(ctypes.c_ubyte)()
    n = ctypes.c_size_t()
    if lib.ktx_encode(src, W, H, fmt.encode(), 1, 0, 90, 2, 0,
                      ctypes.byref(out), ctypes.byref(n)) != 0:
        print(f"FAIL {fmt}: encode: {lib.ktx_last_error().decode()}")
        failures += 1
        continue
    blob = bytes(ctypes.cast(out, ctypes.POINTER(ctypes.c_ubyte * n.value)).contents)
    lib.ktx_free(out)

    dec = ctypes.POINTER(ctypes.c_ubyte)()
    w = ctypes.c_uint()
    h = ctypes.c_uint()
    if lib.ktx_decode(blob, len(blob), 0, 0, 0,
                      ctypes.byref(dec), ctypes.byref(w), ctypes.byref(h)) != 0:
        print(f"FAIL {fmt}: decode: {lib.ktx_last_error().decode()}")
        failures += 1
        continue
    rgba = bytes(ctypes.cast(dec, ctypes.POINTER(ctypes.c_ubyte * (w.value * h.value * 4))).contents)
    lib.ktx_free(dec)

    if (w.value, h.value) != (W, H):
        print(f"FAIL {fmt}: size {w.value}x{h.value}")
        failures += 1
        continue
    mad = sum(abs(a - b) for a, b in zip(rgba, src)) / len(src)
    ok = mad <= tol
    print(f"{'ok  ' if ok else 'FAIL'} {fmt:10s} {len(blob):6d} bytes  mad={mad:.2f} (tol {tol})")
    failures += 0 if ok else 1

sys.exit(1 if failures else 0)
