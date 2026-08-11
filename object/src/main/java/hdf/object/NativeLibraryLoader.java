/*****************************************************************************
 * Copyright by The HDF Group.                                               *
 * Copyright by the Board of Trustees of the University of Illinois.         *
 * All rights reserved.                                                      *
 *                                                                           *
 * This file is part of the HDF Java Products distribution.                  *
 * The full copyright notice, including terms governing use, modification,   *
 * and redistribution, is contained in the COPYING file, which can be found  *
 * at the root of the source code distribution tree,                         *
 * or in https://www.hdfgroup.org/licenses.                                  *
 * If you do not have access to either file, you may request a copy from     *
 * help@hdfgroup.org.                                                        *
 ****************************************************************************/

package hdf.object;

import java.io.File;
import java.io.FilenameFilter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Best-effort preloader that pins HDFView to its bundled HDF5/HDF4 core native
 * libraries.
 *
 * The HDF5 JNI wrapper declares the core
 * library as a {@code NEEDED} dependency, which
 * the OS dynamic loader resolves via {@code PATH} / {@code LD_LIBRARY_PATH},
 * outside of the JVM's control. If a foreign HDF5 installation is visible to the
 * loader, an ABI mismatch can crash the JVM on startup.
 *
 * By {@code System.load}-ing the core library by absolute path before
 * the wrapper initializes, the loader satisfies the wrapper's {@code NEEDED}
 * dependency from the already-mapped module (matched by soname on Linux, by
 * module base name on Windows) and never searches {@code PATH} /
 * {@code LD_LIBRARY_PATH}.
 *
 * This class is best-effort. On failure, the
 * normal {@code H5} load path remains as a fallback.
 */
public final class NativeLibraryLoader {
    private static final Logger log = LoggerFactory.getLogger(NativeLibraryLoader.class);

    /** Guard so the HDF5 core library is preloaded at most once. */
    private static boolean hdf5Preloaded = false;

    /** Guard so the HDF4 core libraries are preloaded at most once. */
    private static boolean hdf4Preloaded = false;

    private NativeLibraryLoader() {}

    /**
     * Preload the bundled HDF5 core library by absolute path, if it can be
     * located.
     */
    public static synchronized void preloadHDF5()
    {
        if (hdf5Preloaded) {
            log.trace("preloadHDF5: already attempted, skipping");
            return;
        }
        // Set the guard up front: a single attempt either way. A failed attempt
        // should not be retried; we fall through to the normal H5 load path.
        hdf5Preloaded = true;

        // The HDF5 JNI wrapper's only core NEEDED dependency is libhdf5.
        loadCore("hdf5", "preloadHDF5");
    }

    /**
     * Preload the bundled HDF4 core libraries by absolute path, if they can be
     * located.
     *
     * The HDF4 JNI wrapper ({@code libhdf_java}) declares two core NEEDED
     * dependencies: {@code libhdf} and {@code libmfhdf}, where {@code libmfhdf}
     * itself depends on {@code libhdf}. They are preloaded in dependency order
     * ({@code libhdf} first) so each is satisfied from an already-mapped module
     * rather than from {@code PATH} / {@code LD_LIBRARY_PATH}.
     */
    public static synchronized void preloadHDF4()
    {
        if (hdf4Preloaded) {
            log.trace("preloadHDF4: already attempted, skipping");
            return;
        }

        hdf4Preloaded = true;

        // Dependency order matters: libhdf has no HDF NEEDED deps, libmfhdf needs
        // libhdf. Loading libhdf first lets libmfhdf bind to the already-mapped
        // module by soname instead of searching the OS library paths.
        loadCore("hdf", "preloadHDF4");
        loadCore("mfhdf", "preloadHDF4");
    }

    /**
     * Resolve and {@code System.load} a single bundled core library by absolute
     * path.
     *
     * @param baseName the platform-independent library base name (e.g. {@code "hdf5"})
     * @param tag      the calling method name, for log context
     */
    private static void loadCore(String baseName, String tag)
    {
        try {
            File resolved = resolveLibrary(baseName);
            if (resolved == null) {
                log.debug("{}: bundled core library '{}' not found in candidate dirs; "
                              + "falling back to default library loading",
                          tag, baseName);
                return;
            }

            System.load(resolved.getAbsolutePath());
            log.debug("{}: preloaded core library from {}", tag, resolved.getAbsolutePath());
        }
        catch (Throwable t) {
            log.debug("{}: preload of '{}' failed, falling back to default library loading", tag, baseName,
                      t);
        }
    }

    /**
     * Resolve the bundled core library file for the given base name (for example
     * {@code "hdf5"}) by scanning the candidate directories in priority order.
     *
     * @param baseName the platform-independent library base name
     * @return the resolved library file, or {@code null} if none was found
     */
    private static File resolveLibrary(String baseName)
    {
        String mappedName = System.mapLibraryName(baseName); // e.g. libhdf5.so / hdf5.dll / libhdf5.dylib

        for (String dir : candidateDirs()) {
            File resolved = resolveInDir(dir, baseName, mappedName);
            if (resolved != null)
                return resolved;
        }
        return null;
    }

    /**
     * Assemble the candidate directories to search, in priority order:
     * <ol>
     * <li>{@code -Dhdfview.nativedir} (explicit override)</li>
     * <li>{@code -Dhdfview.root} (jpackage sets this to {@code $APPDIR})</li>
     * <li>directory of {@code -Dhdf.hdf5lib.H5.hdf5lib} if set</li>
     * <li>each entry of {@code java.library.path}</li>
     * </ol>
     */
    private static List<String> candidateDirs()
    {
        List<String> dirs = new ArrayList<>();

        addIfPresent(dirs, System.getProperty("hdfview.nativedir"));
        addIfPresent(dirs, System.getProperty("hdfview.root"));

        String h5lib = System.getProperty("hdf.hdf5lib.H5.hdf5lib");
        if (h5lib != null && !h5lib.isEmpty()) {
            File parent = new File(h5lib).getParentFile();
            if (parent != null)
                addIfPresent(dirs, parent.getPath());
        }

        String libPath = System.getProperty("java.library.path");
        if (libPath != null && !libPath.isEmpty()) {
            for (String entry : libPath.split(File.pathSeparator))
                addIfPresent(dirs, entry);
        }

        return dirs;
    }

    private static void addIfPresent(List<String> dirs, String dir)
    {
        if (dir != null && !dir.isEmpty() && !dirs.contains(dir))
            dirs.add(dir);
    }

    /**
     * Resolve the concrete library file inside a single directory:
     * <ul>
     * <li>the exact {@code mapLibraryName} result if present, else</li>
     * <li>the versioned form, preferring the plain (unversioned) name when it
     * exists. Linux versions <em>after</em> the extension ({@code libhdf5.so.320}),
     * macOS versions <em>before</em> it ({@code libhdf5.320.dylib}); both are
     * handled. Windows ({@code .dll}) has no versioned form.</li>
     * </ul>
     *
     * @return the resolved file, or {@code null} if this directory has no match
     */
    private static File resolveInDir(String dir, String baseName, String mappedName)
    {
        File directory = new File(dir);
        if (!directory.isDirectory())
            return null;

        // Exact mapLibraryName match (covers Windows .dll, macOS .dylib, and the
        // plain .so symlink on Linux).
        File exact = new File(directory, mappedName);
        if (exact.isFile())
            return exact;

        // Versioned fallback when the plain name is absent.
        FilenameFilter filter = null;
        if (mappedName.endsWith(".so")) {
            // Linux: libhdf5.so.* (e.g. libhdf5.so.320)
            final String prefix = mappedName + ".";
            filter              = (d, name) -> name.startsWith(prefix);
        }
        else if (mappedName.endsWith(".dylib")) {
            // macOS: libhdf5.*.dylib (e.g. libhdf5.320.dylib)
            final String prefix = mappedName.substring(0, mappedName.length() - ".dylib".length()) + ".";
            filter              = (d, name) -> name.startsWith(prefix) && name.endsWith(".dylib");
        }

        if (filter != null) {
            File[] matches = directory.listFiles(filter);
            if (matches != null && matches.length > 0) {
                Arrays.sort(matches); // deterministic pick
                // Prefer the name closest to the plain library name (shortest),
                // then fall back to the first match.
                File best = matches[0];
                for (File f : matches) {
                    if (f.getName().length() < best.getName().length())
                        best = f;
                }
                return best;
            }
        }

        return null;
    }
}
