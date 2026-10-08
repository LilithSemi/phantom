const std = @import("std");
const webidl = @import("webidl");
const appmeta = @import("build/appmeta.zig");

pub const Category = appmeta.Category;
pub const LocalizedText = appmeta.LocalizedText;
pub const Icon = appmeta.Icon;
pub const AppOptions = appmeta.AppOptions;

/// Where a web build serves the built-in fonts, relative to the page. Must match
/// `phantom.text.builtin.font_dir`, which is what the `@font-face` rules point
/// at: the runtime writes the url and this installs the file it names, so the two
/// halves of that agreement live one constant apart.
const phantom_font_dir = "fonts/";

pub fn addApp(b: *std.Build, phantom_dep: *std.Build.Dependency, opts: appmeta.AppOptions) *std.Build.Step {
    const t = opts.target.result;
    const phantom_mod = phantom_dep.module("phantom");

    if (t.cpu.arch == .wasm32) {
        return addWebApp(b, phantom_dep, opts); // Task C5
    }
    const desktop_ok = switch (t.os.tag) {
        // Linux gets the window path and the terminal path.
        .linux => !t.abi.isAndroid(),
        // macOS, the BSDs and Windows get the terminal path only.
        .macos, .freebsd, .netbsd, .openbsd, .windows => true,
        else => false,
    };
    if (!desktop_ok) {
        return &b.addFail("phantom.addApp: this target has neither a window backend nor a terminal backend").step;
    }

    // App root module (the consumer's source exposing `root(*BuildContext) Widget`).
    const app_mod = b.createModule(.{ .root_source_file = opts.root, .target = opts.target, .optimize = opts.optimize });
    app_mod.addImport("phantom", phantom_mod);
    addAppImports(app_mod, phantom_mod, opts.imports);

    // Generated native entry.
    //
    // `pub const panic` here, not in `phantom.zig`: Zig's language level panic
    // mechanism (a bare `@panic`, `unreachable`, a failed bounds or overflow
    // check) looks for that declaration in the ROOT MODULE OF THE COMPILATION,
    // and an imported module's own declaration does not count (see
    // `lib/phantom/panic.zig`'s doc comment). This file IS that root, so it is
    // the one place that reaches every consumer with no action on their part.
    // Harmless for this windowed entry point specifically (`rootPanic`'s restore
    // is a no-op when no `Term` ever called `installCleanup`), and exactly what a
    // terminal entry point needs, so one declaration covers both without a
    // target-specific branch.
    const entry_src =
        \\const std = @import("std");
        \\const phantom = @import("phantom");
        \\const app = @import("app_root");
        \\pub const panic = std.debug.FullPanic(phantom.tui.term.rootPanic);
        \\pub fn main(init: std.process.Init) !void {
        \\    try phantom.App.run(init, phantom.Root.plain(app.root));
        \\}
    ;
    const entry = b.addWriteFiles().add("main.zig", entry_src);
    const exe = b.addExecutable(.{
        .name = execName(b, opts.id, opts.exec_name),
        .root_module = b.createModule(.{ .root_source_file = entry, .target = opts.target, .optimize = opts.optimize }),
    });
    exe.root_module.addImport("phantom", phantom_mod);
    exe.root_module.addImport("app_root", app_mod);

    const step = b.step(b.fmt("app-{s}", .{opts.id}), b.fmt("Package {s} (native)", .{opts.id}));
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // The desktop entry and AppStream metainfo are read by an XDG compliant menu
    // and software centre: GNOME, KDE, and their BSD equivalents. macOS and
    // Windows have no such reader, so installing these files there would only
    // leave two dead paths in the install tree, not a working integration.
    const xdg_ok = switch (t.os.tag) {
        .linux => !t.abi.isAndroid(),
        .freebsd, .netbsd, .openbsd => true,
        else => false,
    };
    if (xdg_ok) {
        // .desktop
        const desktop_text = appmeta.desktopFile(b.allocator, opts, execName(b, opts.id, opts.exec_name)) catch @panic("oom");
        const desktop_lp = b.addWriteFiles().add(b.fmt("{s}.desktop", .{opts.id}), desktop_text);
        step.dependOn(&b.addInstallFileWithDir(desktop_lp, .prefix, b.fmt("share/applications/{s}.desktop", .{opts.id})).step);

        // AppStream metainfo
        const meta_text = appmeta.metainfoXml(b.allocator, opts) catch @panic("oom");
        const meta_lp = b.addWriteFiles().add(b.fmt("{s}.metainfo.xml", .{opts.id}), meta_text);
        step.dependOn(&b.addInstallFileWithDir(meta_lp, .prefix, b.fmt("share/metainfo/{s}.metainfo.xml", .{opts.id})).step);
    }

    // Icons
    for (opts.icons) |icon| {
        const dest = if (icon.size == 0)
            b.fmt("share/icons/hicolor/scalable/apps/{s}.svg", .{opts.id})
        else
            b.fmt("share/icons/hicolor/{d}x{d}/apps/{s}.png", .{ icon.size, icon.size, opts.id });
        step.dependOn(&b.addInstallFileWithDir(icon.path, .prefix, dest).step);
    }

    return step;
}

fn addAppImports(app_mod: *std.Build.Module, phantom_mod: *std.Build.Module, imports: []const std.Build.Module.Import) void {
    for (imports) |import| {
        if (import.module.import_table.get("phantom") == null) {
            import.module.addImport("phantom", phantom_mod);
        }
        app_mod.addImport(import.name, import.module);
    }
}

/// The web page of an app as build outputs, before anything is installed.
pub const WebDist = struct {
    /// The directory that holds the page. Every path in `files` is relative to it.
    dir: std.Build.LazyPath,
    /// Every file of the page, relative to `dir`, as the page refers to it.
    files: []const []const u8,
};

fn addWebApp(b: *std.Build, phantom_dep: *std.Build.Dependency, opts: appmeta.AppOptions) *std.Build.Step {
    const dist_dir = b.fmt("dist/{s}", .{opts.id});
    const web = addWebDist(b, phantom_dep, opts);

    const step = b.step(b.fmt("app-{s}", .{opts.id}), b.fmt("Package {s} (web)", .{opts.id}));
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = web.dir,
        .install_dir = .prefix,
        .install_subdir = dist_dir,
    }).step);

    // Dev-serve: `zig build serve-<name>` serves dist/{id}/ over http via the first
    // available runtime, using an inline zero-dependency static server that sets
    // application/wasm for .wasm (required for WebAssembly.instantiateStreaming).
    addServeStep(b, dist_dir, execName(b, opts.id, opts.exec_name), step);

    return step;
}

/// Build the web page of an app without installing it, for a consumer that
/// serves or embeds the files itself. The page is always built for
/// wasm32-freestanding, whatever `opts.target` is.
pub fn addWebDist(b: *std.Build, phantom_dep: *std.Build.Dependency, opts: appmeta.AppOptions) WebDist {
    const wasm_name = execName(b, opts.id, opts.exec_name);
    const dist = b.addWriteFiles();
    var files: std.ArrayList([]const u8) = .empty;

    // A wrong base_path is a caller mistake, not a runtime fault: fail the
    // build now with a message that says what was expected, rather than
    // install a page whose assets resolve to the wrong place.
    appmeta.validateBasePath(opts.base_path) catch {
        dist.step.dependOn(&b.addFail(b.fmt(
            "phantom.addApp: base_path must start and end with '/', got \"{s}\"",
            .{opts.base_path},
        )).step);
        return .{ .dir = dist.getDirectory(), .files = &.{} };
    };

    // wasm32-freestanding target: no prism/lattice imported so the pure-Zig web
    // decls (web.init / web.WebApp, backend.dom) are analyzed without triggering
    // those native-only deps.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    const phantom_wasm = b.createModule(.{
        .root_source_file = phantom_dep.builder.path("lib/phantom.zig"),
        .target = wasm_target,
        .optimize = opts.optimize,
    });

    // webidl lives in phantom's own dependency tree.
    const webidl_dep = phantom_dep.builder.dependency("webidl", .{});

    // Generate the dom .client Zig bindings from phantom's bundled webidl.
    const dom_client = webidl.generateModule(b, webidl_dep, .{
        .name = "dom",
        .idl = phantom_dep.builder.path("web/dom.webidl"),
        .style = .client,
    });

    // App root module: the consumer's root_source_file built for wasm32.
    const app_mod = b.createModule(.{
        .root_source_file = opts.root,
        .target = wasm_target,
        .optimize = opts.optimize,
    });
    app_mod.addImport("phantom", phantom_wasm);
    addAppImports(app_mod, phantom_wasm, opts.imports);

    // The web entry point is `build/web_entry.zig`, a real file rather than a
    // string in this one: it imports the consumer's source as `app_root`, calls
    // `phantom.web.init`, and exports everything the host page calls. The one
    // per-build value it cannot work out for itself arrives as a build option.
    const entry_options = b.addOptions();
    entry_options.addOption(bool, "strategy_is_hash", opts.url_strategy == .hash);

    const wasm = b.addExecutable(.{
        .name = wasm_name,
        .root_module = b.createModule(.{
            .root_source_file = phantom_dep.builder.path("build/web_entry.zig"),
            .target = wasm_target,
            .optimize = opts.optimize,
        }),
    });
    wasm.root_module.addImport("build_options", entry_options.createModule());
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.addImport("phantom", phantom_wasm);
    wasm.root_module.addImport("dom", dom_client);
    // The generated entry frees the string `dom`'s getters hand back, so it
    // reaches the runtime the same way the generated module itself does.
    wasm.root_module.addImport("webidl", webidl_dep.module("webidl"));
    wasm.root_module.addImport("app_root", app_mod);

    // JS runtime strategy (detected at build time):
    //
    // prebuilt -> copy npm/webidl-runtime/dist/ (multi-file ESM) to
    //             dist/{id}/webidl-runtime/
    //             HTML imports: "./webidl-runtime/index.js"
    //             The webidl dep's npm/.gitignore ignores dist/, so most
    //             checkouts of the dep do NOT commit this directory. Use this
    //             path only when a dist/index.js is actually present.
    //
    // tsc      -> compile npm/webidl-runtime/src/*.ts (multi-file ESM) to an
    //             output directory the build owns, then install it to
    //             dist/{id}/webidl-runtime/
    //             HTML imports: "./webidl-runtime/index.js"
    //             This is the DEFAULT (.auto) when the dep has no committed
    //             dist/index.js. It needs no network access, only tsc on PATH.
    //
    // bun      -> bun build --format esm --entrypoints dist/index.js (opt-in only)
    //             single-file -> dist/{id}/webidl-runtime.js
    // deno     -> deno bundle --platform browser dist/index.js (opt-in only)
    //             single-file -> dist/{id}/webidl-runtime.js
    //             WARNING: both single-file bundlers currently mangle this dep's
    //             pure-re-export entry (they drop the definitions and emit a
    //             nameless `export {...}`, which the browser rejects). Use only if
    //             your bundler is verified to produce a valid module.
    //
    // When opts.web_runtime is .auto the build prefers a committed prebuilt
    // dist and falls back to compiling with tsc when there is none. Explicit
    // .bun / .deno / .tsc pin that strategy; an unavailable tool injects a
    // build-time failure step that names the tool (the wasm is still compiled).

    const wasm_file = b.fmt("{s}.wasm", .{wasm_name});
    _ = dist.addCopyFile(wasm.getEmittedBin(), wasm_file);
    addDistFile(b, &files, wasm_file);

    // Build the webidl-runtime JS and generate a matching index.html.
    const runtime_import = addRuntime(b, webidl_dep, dist, &files, opts.web_runtime);

    // The tab title and description come from the app's own localized text,
    // not the wasm binary's name, so a name with '&' or '"' cannot break the
    // generated document.
    const name_html = appmeta.xmlEscape(b.allocator, opts.name.default) catch @panic("oom");
    const summary_html = appmeta.xmlEscape(b.allocator, opts.summary.default) catch @panic("oom");
    // A prerendered route installs THIS page one directory down, where `./`
    // resolves somewhere else, so the base tag has to be there even at the root.
    const prerendered = opts.url_strategy == .path and opts.prerender_routes.len > 0;
    const html = buildIndexHtml(b, opts.base_path, prerendered, name_html, summary_html);
    _ = dist.add("index.html", html);
    addDistFile(b, &files, "index.html");

    // The page's logic, as a file beside it. See `buildIndexHtml`: an inline
    // script is refused by any strict Content Security Policy, and a blank page
    // with one console violation is a bad first impression of a framework.
    _ = dist.add("boot.js", buildBootJs(b, runtime_import, wasm_name));
    addDistFile(b, &files, "boot.js");

    // The built-in fonts, as files, for the same reason and a sharper one.
    //
    // The alternative is a `@font-face` whose `src` embeds the bytes as a
    // `data:` URL, and `font-src 'self'` refuses that: `font-src` governs where
    // the RESOURCE is fetched from, so no amount of CSSOM changes the answer.
    // A refused font is not an appearance problem. Layout was measured against
    // this font and the browser substitutes another, so the glyphs a person sees
    // and the rectangles their taps are tested against stop agreeing, and the
    // buttons on the page quietly misaim.
    //
    // All of them are installed, not only the ones an application draws with,
    // because which fonts a tree uses is decided when it builds and this is
    // decided now. An unreferenced file is never fetched: only a `@font-face`
    // that some text actually matches costs a request.
    for ([_][]const u8{ "Neuropol.otf", "Mesmerize Rg.otf", "Mesmerize Sb.otf" }) |font_file| {
        const rel = b.fmt("{s}{s}", .{ phantom_font_dir, font_file });
        _ = dist.addCopyFile(phantom_dep.builder.path(b.fmt("lib/phantom/text/fonts/{s}", .{font_file})), rel);
        addDistFile(b, &files, rel);
    }

    // prerender_routes only means something with the .path strategy: a .hash
    // route lives after the '#', so a host never requests the plain path and
    // the extra copy goes unused. Report it rather than fail the build, since
    // the app still works, it just carries a dead copy.
    if (opts.url_strategy == .hash and opts.prerender_routes.len > 0) {
        std.log.warn(
            "phantom.addApp: prerender_routes is set but url_strategy is .hash ({d} routes ignored)",
            .{opts.prerender_routes.len},
        );
    }

    // With the .path strategy, write a standalone copy of the page at each
    // route so a static host answers a refresh with 200 instead of 404.
    // "/gallery" becomes "gallery/index.html", so a static host serves the
    // same application for that path with no rewrite rule. A route with a '/'
    // inside it, such as "/docs/intro", works the same way, because the path
    // keeps the separator.
    if (opts.url_strategy == .path) {
        for (opts.prerender_routes) |route| {
            const trimmed = std.mem.trim(u8, route, "/");
            if (trimmed.len == 0) continue;
            const rel = b.fmt("{s}/index.html", .{trimmed});
            _ = dist.add(rel, html);
            addDistFile(b, &files, rel);
        }
    }

    return .{ .dir = dist.getDirectory(), .files = files.items };
}

fn addDistFile(b: *std.Build, files: *std.ArrayList([]const u8), rel: []const u8) void {
    files.append(b.allocator, rel) catch @panic("OOM");
}

// Inline static server scripts. Each serves a directory on port 8080. A request
// path is remote input, so each script confines every read to the serve root and
// answers 404 for a path that escapes it. The bind address comes from
// PHANTOM_SERVE_HOST and defaults to every interface, so a developer can open the
// site from a second machine on the same network. Set it to 127.0.0.1 for
// loopback only. All three read the dir from the PHANTOM_SERVE_DIR env var
// (node/bun `-e` eval mode does not expose a positional arg at a stable argv
// index, so an env var is used uniformly).
// Content-Type: .wasm -> application/wasm, .js -> text/javascript,
// .html -> text/html, anything else -> application/octet-stream.
// A path with no file extension is a route, not a file, so it maps to that
// path's own index.html. This mirrors the prerendered copies addWebApp
// writes for the .path url strategy, so a browser refresh on a route works
// on the dev server the same way it works on a static host.
// Each script resolves the request against the served root and refuses a
// path that escapes it (a "../" walk answers 404), so a client cannot read
// files elsewhere on the developer's disk.
const node_serve_js = @embedFile("build/serve/node.js");
const bun_serve_js = @embedFile("build/serve/bun.js");
const deno_serve_js = @embedFile("build/serve/deno.js");

fn addServeStep(b: *std.Build, dist_dir: []const u8, name: []const u8, app_step: *std.Build.Step) void {
    const serve = b.step(b.fmt("serve-{s}", .{name}), b.fmt("Serve {s} over http (dev)", .{dist_dir}));
    const out = b.getInstallPath(.prefix, dist_dir);
    // All three scripts read the serve dir from PHANTOM_SERVE_DIR (set below), not a
    // positional arg: node/bun `-e` eval mode does not put the dir at a stable argv
    // index (there is no script-path slot), which broke a positional approach.
    var run: ?*std.Build.Step.Run = null;
    if (b.findProgram(&.{"node"}, &.{}) catch null) |node_bin| {
        run = b.addSystemCommand(&.{ node_bin, "-e", node_serve_js });
    } else if (b.findProgram(&.{"bun"}, &.{}) catch null) |bun_bin| {
        run = b.addSystemCommand(&.{ bun_bin, "-e", bun_serve_js });
    } else if (b.findProgram(&.{"deno"}, &.{}) catch null) |deno_bin| {
        // --allow-env is required: the deno script reads PHANTOM_SERVE_DIR via
        // Deno.env.get, which throws PermissionDenied without it.
        const r = b.addSystemCommand(&.{ deno_bin, "run", "--allow-net", "--allow-read", "--allow-env=PHANTOM_SERVE_DIR,PHANTOM_SERVE_HOST", "-" });
        r.setStdIn(.{ .bytes = deno_serve_js });
        run = r;
    }
    if (run) |r| r.setEnvironmentVariable("PHANTOM_SERVE_DIR", out);
    if (run) |r| {
        // Depend on the app step (which carries all the dist install actions) so the
        // bundle is built regardless of how the consumer wires the app into install.
        r.step.dependOn(app_step);
        serve.dependOn(&r.step);
    } else {
        serve.dependOn(&b.addFail("phantom serve: no node/bun/deno found in PATH").step);
    }
}

/// The modules of the multi-file webidl runtime. tsc compiles one `.ts` source
/// for each, and the prebuilt dist holds one `.js` file for each.
const webidl_runtime_modules = [_][]const u8{ "abi", "host", "index", "loader" };

/// Write the webidl-runtime JS into `dist`. Returns the JS import path to embed
/// in the generated index.html (so HTML and runtime agree).
fn addRuntime(
    b: *std.Build,
    webidl_dep: *std.Build.Dependency,
    dist: *std.Build.Step.WriteFile,
    files: *std.ArrayList([]const u8),
    runtime: appmeta.WebRuntime,
) []const u8 {
    // The committed dist is the exception, not the rule: npm/.gitignore ignores
    // dist/, so most checkouts of the dep have none. Check the real filesystem
    // rather than assume, because a later version of the dep may commit it, and
    // then the copy is both faster and offline.
    const dist_index = webidl_dep.builder.pathFromRoot("npm/webidl-runtime/dist/index.js");
    const has_prebuilt = blk: {
        std.Io.Dir.accessAbsolute(b.graph.io, dist_index, .{}) catch break :blk false;
        break :blk true;
    };
    const have = appmeta.Avail{
        .bun = (b.findProgram(&.{"bun"}, &.{}) catch null) != null,
        .deno = (b.findProgram(&.{"deno"}, &.{}) catch null) != null,
        .node = (b.findProgram(&.{"node"}, &.{}) catch null) != null,
        .tsc = (b.findProgram(&.{"tsc"}, &.{}) catch null) != null,
        .prebuilt = has_prebuilt,
    };
    const strategy = appmeta.resolveStrategy(runtime, have) catch {
        // .auto tries the committed dist first and falls back to tsc, so an
        // unresolved .auto always means tsc is the missing tool.
        const missing_tool: []const u8 = if (runtime == .auto) "tsc" else @tagName(runtime);
        dist.step.dependOn(&b.addFail(b.fmt(
            "phantom.addApp: the web target needs {s}, but it was not found in PATH",
            .{missing_tool},
        )).step);
        return appmeta.importPathFor(.prebuilt);
    };
    // Bundle the dep's already-transpiled dist/index.js (clean ESM with .js imports,
    // type-exports stripped), NOT the raw src/index.ts: bundling the TS source
    // produced an invalid module ("local binding for export 'createHost' not found",
    // from the .ts-extension re-exports + the mixed value/type export). The dist is
    // the same tsc output the prebuilt strategy copies.
    const bundle_entry = webidl_dep.builder.path("npm/webidl-runtime/dist/index.js");
    switch (strategy) {
        .bun => {
            const run = b.addSystemCommand(&.{ (b.findProgram(&.{"bun"}, &.{}) catch unreachable), "build", "--format", "esm", "--entrypoints" });
            run.addFileArg(bundle_entry);
            run.addArg("--outfile");
            _ = dist.addCopyFile(run.addOutputFileArg("webidl-runtime.js"), "webidl-runtime.js");
            addDistFile(b, files, "webidl-runtime.js");
        },
        .deno => {
            // deno bundle (Deno 2.8.3, native/offline). This is the browser single-file form.
            const run = b.addSystemCommand(&.{ (b.findProgram(&.{"deno"}, &.{}) catch unreachable), "bundle", "--platform", "browser" });
            run.addFileArg(bundle_entry);
            run.addArg("--output");
            _ = dist.addCopyFile(run.addOutputFileArg("webidl-runtime.js"), "webidl-runtime.js");
            addDistFile(b, files, "webidl-runtime.js");
        },
        .tsc => {
            // Compile the TS source directly (not the missing dist): --outDir
            // goes to a path the build owns, because the package cache is read
            // only. --rewriteRelativeImportExtensions turns the sources' explicit
            // `.ts` imports into `.js`, which is what the browser needs to load
            // the emitted module graph; it needs TypeScript 5.7 or newer.
            // node-fs.d.ts is an ambient declaration for `node:fs/promises`
            // (loader.ts's non-browser file-read path); it emits no JS but is
            // required for the type check to pass.
            const run = b.addSystemCommand(&.{
                (b.findProgram(&.{"tsc"}, &.{}) catch unreachable),
                "--target",
                "ES2022",
                "--module",
                "ES2022",
                "--moduleResolution",
                "bundler",
                "--rewriteRelativeImportExtensions",
                "--strict",
                "--declaration",
                "false",
                "--outDir",
            });
            const out_dir = run.addOutputDirectoryArg("webidl-runtime");
            for (webidl_runtime_modules) |name| {
                run.addFileArg(webidl_dep.builder.path(b.fmt("npm/webidl-runtime/src/{s}.ts", .{name})));
            }
            run.addFileArg(webidl_dep.builder.path("npm/webidl-runtime/src/node-fs.d.ts"));
            addRuntimeModules(b, out_dir, dist, files);
        },
        .prebuilt => addRuntimeModules(b, webidl_dep.builder.path("npm/webidl-runtime/dist"), dist, files),
    }
    return appmeta.importPathFor(strategy);
}

fn addRuntimeModules(
    b: *std.Build,
    js_dir: std.Build.LazyPath,
    dist: *std.Build.Step.WriteFile,
    files: *std.ArrayList([]const u8),
) void {
    for (webidl_runtime_modules) |name| {
        const rel = b.fmt("webidl-runtime/{s}.js", .{name});
        _ = dist.addCopyFile(js_dir.path(b, b.fmt("{s}.js", .{name})), rel);
        addDistFile(b, files, rel);
    }
}

/// The page itself: a shell with no logic in it at all.
///
/// The boot script is a FILE rather than an inline `<script>`, because an inline
/// one is refused outright by any Content Security Policy without
/// `'unsafe-inline'` or a nonce, and `script-src 'self'` is the ordinary strict
/// setting. Inline, not one byte of the application runs and the page is blank
/// with a console violation. As a file it is `'self'` and needs no policy change
/// from anyone.
///
/// `<base>` is emitted only when it does something.
///
/// It fixes where `./boot.js` and `./app.wasm` resolve from, and it is needed in
/// exactly two cases: an application served under a sub-path, and a prerendered
/// route, where THE SAME page is installed at `/gallery/index.html` and would
/// otherwise look for its script one directory down. A page served from the root
/// with no prerendered copies needs none of that, and `base-uri 'none'` refuses
/// the tag, so emitting it there buys a policy violation on every load and
/// nothing else.
fn buildIndexHtml(
    b: *std.Build,
    base_path: []const u8,
    prerendered: bool,
    name_html: []const u8,
    summary_html: []const u8,
) []const u8 {
    const base_tag = if (std.mem.eql(u8, base_path, "/") and !prerendered)
        ""
    else
        b.fmt("\n    <base href=\"{s}\" />", .{base_path});
    return b.fmt(
        \\<!DOCTYPE html>
        \\<html>
        \\  <head>
        \\    <meta charset="utf-8" />{s}
        \\    <title>{s}</title>
        \\    <meta name="description" content="{s}" />
        \\  </head>
        \\  <body>
        \\    <script type="module" src="./boot.js"></script>
        \\  </body>
        \\</html>
    , .{ base_tag, name_html, summary_html });
}

/// Everything the page does, as a module served beside the wasm. See
/// `buildIndexHtml` for why this is not inline.
fn buildBootJs(b: *std.Build, runtime_import: []const u8, wasm_name: []const u8) []const u8 {
    const with_runtime = std.mem.replaceOwned(u8, b.allocator, @embedFile("build/boot.js"), "@runtime_import@", runtime_import) catch @panic("OOM");
    return std.mem.replaceOwned(u8, b.allocator, with_runtime, "@wasm_name@", wasm_name) catch @panic("OOM");
}

fn execName(b: *std.Build, id: []const u8, exec_name: ?[]const u8) []const u8 {
    return b.dupe(appmeta.resolveExecName(id, exec_name));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gpu_drivers = b.option([]const u8, "gpu-drivers", "Specific GPU drivers to enable, defaults to Prism's choice.");

    const phantom = b.addModule("phantom", .{
        .root_source_file = b.path("lib/phantom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lattice_dep = b.dependency("lattice", .{
        .target = target,
        .optimize = optimize,
        .@"gpu-drivers" = gpu_drivers,
    });

    const prism_dep = b.dependency("prism", .{
        .target = target,
        .optimize = optimize,
        .drivers = gpu_drivers,
    });

    phantom.addImport("lattice", lattice_dep.module("lattice"));
    phantom.addImport("prism", prism_dep.module("prism"));

    // Every task in the terminal plan runs one named test. Without a filter the
    // full suite runs each time, which hides which test the task actually proved.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only the tests whose name contains one of these substrings",
    ) orelse &[0][]const u8{};

    const tests = b.addTest(.{ .root_module = phantom, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Phantom unit tests");
    test_step.dependOn(&run_tests.step);

    const meta_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/appmeta.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(meta_tests).step);

    // run-hello: the padded blue box in a real Lattice window (Wayland, else headless).
    const hello = b.addExecutable(.{
        .name = "phantom-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello.root_module.addImport("phantom", phantom);
    b.installArtifact(hello);
    const run_hello = b.addRunArtifact(hello);
    const run_hello_step = b.step("run-hello", "Run the Phantom hello window (Wayland)");
    run_hello_step.dependOn(&run_hello.step);

    // run-hello:web: the same padded blue box, compiled to wasm and rendered to the DOM
    // via the DomBackend string path + webidl .client bindings. The web path is pure Zig
    // (no prism/lattice), so this phantom module is built for wasm WITHOUT those deps: the
    // native-only decls (App, PrismBackend) are never referenced by the web entry, so they
    // are not analyzed and their prism/lattice imports are never triggered.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const phantom_wasm = b.createModule(.{
        .root_source_file = b.path("lib/phantom.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const webidl_dep = b.dependency("webidl", .{});
    const dom_client = webidl.generateModule(b, webidl_dep, .{
        .name = "dom",
        .idl = b.path("web/dom.webidl"),
        .style = .client,
    });

    const hello_web = b.addExecutable(.{
        .name = "phantom-hello-web",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hello_web.zig"),
            .target = wasm_target,
            .optimize = optimize,
        }),
    });
    hello_web.entry = .disabled;
    hello_web.rdynamic = true;
    hello_web.root_module.addImport("phantom", phantom_wasm);
    hello_web.root_module.addImport("dom", dom_client);

    const install_web = b.addInstallArtifact(hello_web, .{});
    const install_html = b.addInstallFile(b.path("web/index.html"), "index.html");
    const web_step = b.step("run-hello:web", "Build the Phantom web (CSR) demo (wasm + html)");
    web_step.dependOn(&install_web.step);
    web_step.dependOn(&install_html.step);

    // run-hello:tui: the terminal path. It needs a real terminal, so this is a
    // manual check and not part of `zig build test`.
    const hello_tui = b.addExecutable(.{
        .name = "phantom-hello-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    hello_tui.root_module.addImport("phantom", phantom);
    b.installArtifact(hello_tui);
    const run_hello_tui = b.addRunArtifact(hello_tui);
    const run_hello_tui_step = b.step("run-hello:tui", "Run the Phantom terminal demo");
    run_hello_tui_step.dependOn(&run_hello_tui.step);
}
