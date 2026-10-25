# ANGLE as two DLLs (libEGL.dll, libGLESv2.dll) on the dynamic MSVC runtime, like libmpv.
# Its dependencies (zlib) are linked in statically, so the release ships no extra DLL.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
if(PORT STREQUAL "angle")
  set(VCPKG_LIBRARY_LINKAGE dynamic)
else()
  set(VCPKG_LIBRARY_LINKAGE static)
endif()
# Safeer, utrjena gradnja (25. 10. 2026): Control Flow Guard in CET shadow stack kot paketi distribucije. Brez njiju je
# pe_utrjenost.py v paketu Safeer za Windows izmeril libEGL/libGLESv2 brez CETCOMPAT (r1).
set(VCPKG_C_FLAGS "/guard:cf")
set(VCPKG_CXX_FLAGS "/guard:cf")
set(VCPKG_LINKER_FLAGS "/guard:cf /CETCOMPAT")
