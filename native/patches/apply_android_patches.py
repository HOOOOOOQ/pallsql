#!/usr/bin/env python3
"""Apply the minimal MariaDB source patches needed for the Android cross build.

Usage: python3 native/patches/apply_android_patches.py <mariadb-source-dir>

Every patch is applied to the *extracted* release archive inside CI. Nothing is
patched in the PALLSQL repository, and the script fails loudly (with the exact
line it expected) when upstream changes, so the build can never silently fall
back to a configuration that was not reviewed.

The patches are build-configuration only: no server logic is modified.
"""

from __future__ import annotations

import pathlib
import sys


def patch(relative: str, old: str, new: str, expected: int = 1) -> None:
    path = pathlib.Path(sys.argv[1]) / relative
    text = path.read_text()
    found = text.count(old)
    if found != expected:
        raise SystemExit(
            f"{relative}: expected {expected} occurrence(s) of {old!r}, found {found}"
        )
    path.write_text(text.replace(old, new))
    print(f"patched {relative}")


def main() -> int:
    root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
    if root is None or not root.is_dir():
        raise SystemExit("usage: apply_android_patches.py <mariadb-source-dir>")

    # 1. `mariadbd` never links readline and the NDK ships no ncurses for the
    #    target ABI, yet CMakeLists.txt probes for curses unconditionally.
    patch(
        "CMakeLists.txt",
        "MYSQL_CHECK_READLINE()",
        "\n".join(
            [
                "# PALLSQL Android port: no ncurses in the NDK and mariadbd does",
                "# not link readline, so the probe is skipped for this build.",
                "IF(NOT ANDROID)",
                "  MYSQL_CHECK_READLINE()",
                "ENDIF()",
            ]
        ),
    )

    # 2. MRG_MyISAM is declared MANDATORY, so no CMake option can remove it.
    #    PALLSQL ships InnoDB + Aria only, and myrg_static.c does not compile
    #    against the Android sysroot.
    plugin = (
        "MYSQL_ADD_PLUGIN(myisammrg ${MYISAMMRG_SOURCES} STORAGE_ENGINE "
        "MANDATORY RECOMPILE_FOR_EMBEDDED)"
    )
    patch(
        "storage/myisammrg/CMakeLists.txt",
        plugin,
        "# PALLSQL Android port: the phone build ships InnoDB + Aria only.\n"
        f"# {plugin}",
    )

    # 3. The bundled PCRE2 is an ExternalProject that forwards only
    #    CMAKE_C_COMPILER. Under the NDK that variable points at the generic
    #    `clang`, whose default target is the host, so pcre2 was built for
    #    x86-64 and the final link failed with "incompatible with aarch64linux".
    compiler_line = '      "-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"\n'
    patch(
        "cmake/pcre.cmake",
        compiler_line,
        compiler_line
        + '      "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}"\n'
        + '      "-DANDROID_ABI=${ANDROID_ABI}"\n'
        + '      "-DANDROID_PLATFORM=${ANDROID_PLATFORM}"\n',
    )

    # 4. With WITH_SSL=bundled the Connector/C TLS backend is forced to GnuTLS
    #    on every non-Windows system. PALLSQL ships its own protocol client and
    #    never links Connector/C, so the Android build configures it without a
    #    TLS backend instead of pulling a host GnuTLS into a cross build.
    patch(
        "cmake/mariadb_connector_c.cmake",
        '    SET(CONC_WITH_SSL "GNUTLS") # that\'s what debian wants, right?',
        "\n".join(
            [
                "    IF(ANDROID)",
                '      SET(CONC_WITH_SSL "OFF")',
                "    ELSE()",
                '      SET(CONC_WITH_SSL "GNUTLS")',
                "    ENDIF()",
            ]
        ),
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
