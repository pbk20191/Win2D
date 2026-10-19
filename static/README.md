# Win2D as static libraries (`static-lib` branch)

This branch of [pbk20191/Win2D](https://github.com/pbk20191/Win2D) is upstream
[microsoft/Win2D](https://github.com/microsoft/Win2D) `winappsdk/main` at
`25680382dd2136779e10ea6084f0c5ba437ae288` (Win2D-WinUI 1.4.0) plus only these files:

| File | Purpose |
|---|---|
| `static/module_static.cpp` | Replacement for `winrt/dll/module.cpp`: no `DllMain`, exports `Win2DStatic_DllGetActivationFactory` / `Win2DStatic_DllGetClassObject`. |
| `static/build-static.ps1` | Restores packages, builds `winrt.lib` and `win2dmod.lib` for one platform, stages them with their PDBs and `BUILDINFO.txt`. |
| `.github/workflows/static-lib.yml` | CI: builds x64 and ARM64 and uploads `win2d-static-x64` / `win2d-static-ARM64` artifacts (90-day retention). A `win2d-static-v*` tag also publishes a GitHub Release. |

No existing Win2D file is modified. Everything is driven by MSBuild global properties.

It lets an app link Win2D straight into its exe (for example a .NET NativeAOT app) instead of
shipping `Microsoft.Graphics.Canvas.dll`. Microsoft does not support Win2D built this way.

## What gets built

- `winrt.lib`: `winrt/lib/winrt.lib.uap.vcxproj`, which upstream already builds as a StaticLibrary
  containing all of Win2D. It is built `Release|<platform>` with
  `WindowsTargetPlatformVersion=10.0.22621.0` and `WholeProgramOptimization=false`, so it contains
  plain COFF objects rather than LTCG IL. It is about 100 MB.
- `win2dmod.lib`: `static/module_static.cpp`, compiled with `cl /MT /O1 /Qspectre /guard:cf`.
  It contains no `DllMain`. ETW and TraceLogging registration run through `std::call_once` on the
  first activation, and the unregistration that `DllMain` does on detach is skipped.
- CRT model: hybrid. Both libs use `/MT` (`LIBCMT`/`libcpmt`, `_ITERATOR_DEBUG_LEVEL=0`) and expect
  the final link to use the UCRT DLL (`/NODEFAULTLIB:libucrt.lib /DEFAULTLIB:ucrt.lib`). NativeAOT
  links exactly this way, so there is no LNK2038 mismatch.
- Toolset: MSVC is pinned to the newest installed 14.44.x or older (`-MaxMsvc`), because
  consumers link with MSVC 14.44.35207 and objects from a newer compiler can need a newer linker.
  `BUILDINFO.txt` records the exact MSVC, `cl` and SDK versions.
- Debug info: both libs are compiled `/Zi`. `winrt.lib` is built by the unmodified upstream
  project, whose objects reference the compiler PDB `winrt.pdb` (`/Fd$(OutDir)winrt.pdb`); the shim
  is compiled with `/Fd...\win2dmod.pdb`. The recorded paths are absolute build-machine paths,
  but `link.exe` first looks for the PDB by file name next to the `.lib`, so both PDBs are
  shipped beside their libs under exactly those names.

## Downloads

Tagged builds are published as [GitHub Releases](https://github.com/pbk20191/Win2D/releases).
Tag `win2d-static-v<version>` (for example `win2d-static-v1.4.0-1`: Win2D 1.4.0, build 1) has:

```
https://github.com/pbk20191/Win2D/releases/download/win2d-static-v<version>/win2d-static-<version>-x64.zip
https://github.com/pbk20191/Win2D/releases/download/win2d-static-v<version>/win2d-static-<version>-ARM64.zip
https://github.com/pbk20191/Win2D/releases/download/win2d-static-v<version>/SHA256SUMS.txt
```

Each zip holds `winrt.lib`, `winrt.pdb`, `win2dmod.lib`, `win2dmod.pdb` and `BUILDINFO.txt` at
its root. Check it with `sha256sum -c SHA256SUMS.txt` (or `Get-FileHash`). x64 is smoke-tested
by linking and running a NativeAOT probe; ARM64 is build-verified only and has not been run.
This is an unofficial build of MIT-licensed Win2D, not supported by Microsoft.

Untagged pushes to `static-lib` only produce workflow artifacts with the same contents.

## Build locally

You need Visual Studio 2022 with the C++ x64 and ARM64 tools (MSVC 14.44) and Windows SDK
10.0.22621.

```powershell
pwsh static\build-static.ps1 -Platform x64   -OutDir out\x64
pwsh static\build-static.ps1 -Platform ARM64 -OutDir out\ARM64
```

If winmdidl or abi.exe fails because the checkout path is too long (MAX_PATH), add
`-SubstDrive W` to build through a `subst` drive.

## Consuming from a NativeAOT project

Download the release zip (or workflow artifact) for your RID (`x64` for `win-x64`, `ARM64` for
`win-arm64`), unzip it into one folder, and add the following to the csproj:

```xml
<PropertyGroup>
  <Win2DStaticDir>path\to\win2d-static-x64\</Win2DStaticDir>
</PropertyGroup>
<ItemGroup>
  <!-- Keep the managed projection (Microsoft.Graphics.Canvas.Interop etc.), drop the native DLL. -->
  <PackageReference Include="Microsoft.Graphics.Win2D" ExcludeAssets="native" />

  <!-- Bind [LibraryImport("Microsoft.Graphics.Canvas")] statically. -->
  <DirectPInvoke Include="Microsoft.Graphics.Canvas" />

  <NativeLibrary Include="$(Win2DStaticDir)win2dmod.lib" />
  <NativeLibrary Include="$(Win2DStaticDir)winrt.lib" />
  <NativeLibrary Include="d2d1.lib;d3d11.lib;d3dcompiler.lib;windowscodecs.lib;dwrite.lib;runtimeobject.lib;rpcrt4.lib;shcore.lib;dxgi.lib;delayimp.lib" />

  <!-- WRL registers activatable classes through linker sections; pull every object in. -->
  <LinkerArg Include="/WHOLEARCHIVE:$(Win2DStaticDir)winrt.lib" />
  <LinkerArg Include="/DELAYLOAD:d3dcompiler_47.dll" />
</ItemGroup>
```

Keep `winrt.pdb` and `win2dmod.pdb` in the same folder as the libs. If they are missing or
renamed, the link still succeeds but prints one `LNK4099: PDB 'winrt.pdb' was not found` warning
per object (about 140) and the exe's PDB has no Win2D type or local-variable information. With
the PDBs in place the link prints no LNK4099. The PDBs are only read at link time; nothing
needs to ship with the exe.

### Routing activation with CsWinRT

CsWinRT (WinRT.Runtime 2.2) exposes
`public static Func<string, Guid, IntPtr> WinRT.ActivationFactory.ActivationHandler { get; set; }`.
`ActivationFactory.Get(string, Guid)` calls it first and falls back to default activation
(`RoGetActivationFactory`) when it returns zero. Install a handler before any Win2D type is
used (for example on the first line of `Program.cs`). For class names that start with
`Microsoft.Graphics.Canvas.`, the handler:

1. creates an HSTRING for the class name;
2. calls `Win2DStatic_DllGetActivationFactory`, bound statically through
   `[LibraryImport("Microsoft.Graphics.Canvas", EntryPoint = "Win2DStatic_DllGetActivationFactory")]`
   together with `DirectPInvoke`;
3. QueryInterfaces the factory for the requested IID and returns that pointer.

```csharp
using System.Runtime.InteropServices;

internal static unsafe partial class Win2DStatic
{
    private const string Prefix = "Microsoft.Graphics.Canvas.";

    public static void Install() => WinRT.ActivationFactory.ActivationHandler = Activate;

    private static IntPtr Activate(string typeName, Guid iid)
    {
        if (!typeName.StartsWith(Prefix, StringComparison.Ordinal))
            return IntPtr.Zero; // default activation (RoGetActivationFactory)

        IntPtr hstring;
        fixed (char* chars = typeName)
            Marshal.ThrowExceptionForHR(WindowsCreateString(chars, (uint)typeName.Length, &hstring));
        IntPtr factory;
        int hr;
        try { hr = DllGetActivationFactory(hstring, &factory); }
        finally { WindowsDeleteString(hstring); }
        Marshal.ThrowExceptionForHR(hr);
        try
        {
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory, in iid, out var result));
            return result; // CsWinRT takes ownership of this reference
        }
        finally { Marshal.Release(factory); }
    }

    [LibraryImport("Microsoft.Graphics.Canvas", EntryPoint = "Win2DStatic_DllGetActivationFactory")]
    private static partial int DllGetActivationFactory(IntPtr activatableClassId, IntPtr* factory);

    [LibraryImport("api-ms-win-core-winrt-string-l1-1-0.dll")]
    private static partial int WindowsCreateString(char* sourceString, uint length, IntPtr* hstring);

    [LibraryImport("api-ms-win-core-winrt-string-l1-1-0.dll")]
    private static partial int WindowsDeleteString(IntPtr hstring);
}
```

## Limitations

- Only activation that goes through CsWinRT is routed. A direct `RoGetActivationFactory` call
  for a `Microsoft.Graphics.Canvas.*` class fails with `REGDB_E_CLASSNOTREG` (0x80040154).
- `DllCanUnloadNow` and the `DllMain` detach cleanup are not provided.
- The build depends on the public `shine-oss/Win2D-Dependencies` NuGet feed (see `nuget.config`).
- The final link must use an MSVC linker at least as new as the toolset in `BUILDINFO.txt`.
