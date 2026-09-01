module vibe_search.desktop.window_host;

import std.stdio;
import dui;
import glfw3.api;

version (Windows)
{
    import core.sys.windows.windows;
    extern (C) HWND glfwGetWin32Window(GLFWwindow* window);
}
else version (linux)
{
    extern (C) void* glfwGetX11Display();
    extern (C) ulong glfwGetX11Window(GLFWwindow* window);
    extern (C) void* glfwGetWaylandDisplay();
    extern (C) void* glfwGetWaylandWindow(GLFWwindow* window);
}

/// Run the desktop host (Vello GPU when built with `-c gpu`, else software blit).
void runDesktopWindow(ref DuiApp app, const(char)[] title, uint winW = 960, uint winH = 720) @trusted
{
    version (VibeGpuWindow)
        runVelloWindow(app, title, winW, winH);
    else
        runSoftwareWindow(app, title, winW, winH);
}

version (VibeGpuWindow)
{
    /// Run a GLFW window with Vello; re-layout and re-render on every resize frame.
    void runVelloWindow(ref DuiApp app, const(char)[] title, uint winW = 960, uint winH = 720) @trusted
    {
        if (!glfwInit())
        {
            stderr.writeln("glfwInit failed");
            return;
        }
        scope (exit)
            glfwTerminate();

        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        auto window = glfwCreateWindow(cast(int) winW, cast(int) winH, title.ptr, null, null);
        if (window is null)
        {
            stderr.writeln("glfwCreateWindow failed");
            return;
        }
        scope (exit)
            glfwDestroyWindow(window);

        auto gpu = new VelloRenderBackend();
        if (!attachVelloBackend(gpu, window, winW, winH))
        {
            stderr.writeln("VelloRenderBackend attach failed");
            return;
        }
        scope (exit)
            gpu.shutdown();

        Arena frameArena;
        scope (exit)
            frameArena.dispose();

        app.dew.ui.arena = &frameArena;
        app.dew.backend = gpu;

        runEventLoop(app, window);
    }

    private bool attachVelloBackend(VelloRenderBackend gpu, GLFWwindow* window, uint w, uint h) @trusted
    {
        version (Windows)
        {
            HWND hwnd = glfwGetWin32Window(window);
            HINSTANCE hinstance = GetModuleHandleA(null);
            gpu.attach(cast(void*) hwnd, cast(void*) hinstance, w, h);
            return gpu.attached;
        }
        else version (linux)
        {
            auto wlDisp = glfwGetWaylandDisplay();
            auto wlSurf = glfwGetWaylandWindow(window);
            if (wlDisp !is null && wlSurf !is null)
            {
                gpu.attachWayland(wlDisp, wlSurf, w, h);
                if (gpu.attached)
                    return true;
            }
            auto xDisp = glfwGetX11Display();
            auto xWin = glfwGetX11Window(window);
            if (xDisp !is null && xWin != 0)
            {
                gpu.attachX11(xDisp, xWin, 0, w, h);
                return gpu.attached;
            }
            return false;
        }
        else
            return false;
    }
}
else
{
    /// CPU raster + Win32 GDI blit; still re-layouts every resize frame.
    void runSoftwareWindow(ref DuiApp app, const(char)[] title, uint winW = 960, uint winH = 720) @trusted
    {
        if (!glfwInit())
        {
            stderr.writeln("glfwInit failed");
            return;
        }
        scope (exit)
            glfwTerminate();

        glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
        auto window = glfwCreateWindow(cast(int) winW, cast(int) winH, title.ptr, null, null);
        if (window is null)
        {
            stderr.writeln("glfwCreateWindow failed");
            return;
        }
        scope (exit)
            glfwDestroyWindow(window);

        auto cpu = new SoftwareBackend(winW, winH);
        app.dew.backend = cpu;
        runEventLoop(app, window);
    }
}

private enum PendingKind : ubyte { None, Named, Char }

private struct PendingKey
{
    PendingKind kind;
    KeyPhase phase;
    bool shift, ctrl, alt, meta;
    char[16] named;
    ubyte namedLen;
    char ch;
}

private __gshared PendingKey[16] pendingKeys;
private __gshared size_t pendingHead;
private __gshared size_t pendingTail;

private bool enqueuePending(PendingKey item) @nogc nothrow
{
    const next = (pendingHead + 1) % pendingKeys.length;
    if (next == pendingTail)
        return false;
    pendingKeys[pendingHead] = item;
    pendingHead = next;
    return true;
}

private void drainPendingKeys(DuiApp* app) @trusted
{
    while (pendingTail != pendingHead)
    {
        const item = pendingKeys[pendingTail];
        pendingTail = (pendingTail + 1) % pendingKeys.length;

        KeyEvent ev;
        ev.phase = item.phase;
        ev.shift = item.shift;
        ev.ctrl = item.ctrl;
        ev.alt = item.alt;
        ev.meta = item.meta;
        if (item.kind == PendingKind.Named && item.namedLen > 0)
            ev.key = item.named[0 .. item.namedLen].idup;
        else if (item.kind == PendingKind.Char)
        {
            char[1] ch = [item.ch];
            ev.key = ch[].idup;
        }
        else
            continue;
        dispatchKey(app, ev);
    }
}

private void runEventLoop(ref DuiApp app, GLFWwindow* window) @trusted
{
    glfwSetWindowUserPointer(window, cast(void*) &app);
    glfwSetKeyCallback(window, &onGlfwKey);
    glfwSetCharCallback(window, &onGlfwChar);

    syncWindowSize(app, window);
    app.frame();
    presentFrame(app, window);

    bool mouseWasDown;
    while (!glfwWindowShouldClose(window))
    {
        glfwPollEvents();
        drainPendingKeys(&app);

        if (syncWindowSize(app, window))
            app.requestRebuild();

        double mx, my;
        glfwGetCursorPos(window, &mx, &my);
        const down = glfwGetMouseButton(window, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS;

        if (down != mouseWasDown)
        {
            PointerEvent ev;
            ev.x = cast(float) mx;
            ev.y = cast(float) my;
            ev.kind = PointerKind.Mouse;
            ev.phase = down ? PointerPhase.Down : PointerPhase.Up;
            ev.button = PointerButton.Left;
            ev.pressed = down;
            ev.primary = true;
            if (app.pointer(ev))
                app.frame();
        }
        else if (down)
        {
            PointerEvent ev;
            ev.x = cast(float) mx;
            ev.y = cast(float) my;
            ev.kind = PointerKind.Mouse;
            ev.phase = PointerPhase.Move;
            ev.button = PointerButton.Left;
            ev.pressed = true;
            ev.primary = true;
            app.pointer(ev);
        }
        mouseWasDown = down;

        app.frame();
        presentFrame(app, window);
    }
}

private void presentFrame(ref DuiApp app, GLFWwindow* window) @trusted
{
    version (Windows)
    {
        if (auto cpu = cast(SoftwareBackend) app.dew.backend)
        {
            HWND hwnd = glfwGetWin32Window(window);
            blitSoftwareToHwnd(hwnd, cpu.pixels, cpu.width, cpu.height);
        }
    }
}

version (Windows)
{
    private void blitSoftwareToHwnd(HWND hwnd, const(ubyte)[] pixels, uint srcW, uint srcH) @trusted
    {
        if (hwnd is null || pixels.length == 0 || srcW == 0 || srcH == 0)
            return;

        RECT rc;
        if (!GetClientRect(hwnd, &rc))
            return;
        const dstW = rc.right - rc.left;
        const dstH = rc.bottom - rc.top;
        if (dstW <= 0 || dstH <= 0)
            return;

        HDC hdc = GetDC(hwnd);
        if (hdc is null)
            return;
        scope (exit)
            ReleaseDC(hwnd, hdc);

        BITMAPINFO bmi;
        bmi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        bmi.bmiHeader.biWidth = cast(LONG) srcW;
        bmi.bmiHeader.biHeight = -cast(LONG) srcH;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;

        StretchDIBits(
            hdc,
            0, 0, dstW, dstH,
            0, 0, cast(int) srcW, cast(int) srcH,
            cast(void*) pixels.ptr,
            &bmi,
            DIB_RGB_COLORS,
            SRCCOPY);
    }
}

private DuiApp* appPtr(GLFWwindow* window) @trusted @nogc nothrow
{
    return cast(DuiApp*) glfwGetWindowUserPointer(window);
}

extern (C) void onGlfwKey(GLFWwindow* window, int key, int, int action, int mods) nothrow @nogc
{
    auto app = appPtr(window);
    if (app is null || action == GLFW_RELEASE)
        return;

    PendingKey item;
    item.kind = PendingKind.Named;
    item.phase = action == GLFW_REPEAT ? KeyPhase.Repeat : KeyPhase.Down;
    item.shift = (mods & GLFW_MOD_SHIFT) != 0;
    item.ctrl = (mods & GLFW_MOD_CONTROL) != 0;
    item.alt = (mods & GLFW_MOD_ALT) != 0;
    item.meta = (mods & GLFW_MOD_SUPER) != 0;
    item.namedLen = cast(ubyte) writeNamedKey(key, item.named[]);
    if (item.namedLen == 0)
        return;
    enqueuePending(item);
}

extern (C) void onGlfwChar(GLFWwindow* window, uint codepoint) nothrow @nogc
{
    auto app = appPtr(window);
    if (app is null || codepoint > 127)
        return;

    PendingKey item;
    item.kind = PendingKind.Char;
    item.phase = KeyPhase.Down;
    item.ch = cast(char) codepoint;
    enqueuePending(item);
}

private size_t writeNamedKey(int key, char[] buf) @nogc nothrow
{
    const(char)[] name = glfwKeyName(key);
    if (name.length == 0 || name.length > buf.length)
        return 0;
    buf[0 .. name.length] = name;
    return name.length;
}

private void dispatchKey(DuiApp* app, KeyEvent ev) @trusted
{
    if (app.key(ev))
        app.frame();
}

private bool syncWindowSize(ref DuiApp app, GLFWwindow* window) @trusted
{
    int fbW, fbH;
    glfwGetFramebufferSize(window, &fbW, &fbH);
    float sx, sy;
    glfwGetWindowContentScale(window, &sx, &sy);
    auto scale = ScaleFactor(sx, sy);
    if (fbW <= 0 || fbH <= 0)
        return false;
    if (fbW == cast(int) app.dew.physicalWidth
        && fbH == cast(int) app.dew.physicalHeight
        && approxEqualScale(app.dew.contentScale, scale))
        return false;
    app.dew.syncFromFramebuffer(fbW, fbH, scale);
    app.resize(app.dew.logicalWidth, app.dew.logicalHeight);
    return true;
}

private bool approxEqualScale(ScaleFactor a, ScaleFactor b, float eps = 1e-3f) @nogc nothrow
{
    import std.math : abs;
    return abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps;
}

private const(char)[] glfwKeyName(int key) @nogc nothrow
{
    switch (key)
    {
    case GLFW_KEY_BACKSPACE: return "Backspace";
    case GLFW_KEY_TAB: return "Tab";
    case GLFW_KEY_ENTER: return "Enter";
    case GLFW_KEY_ESCAPE: return "Escape";
    case GLFW_KEY_DELETE: return "Delete";
    case GLFW_KEY_LEFT: return "ArrowLeft";
    case GLFW_KEY_RIGHT: return "ArrowRight";
    case GLFW_KEY_UP: return "ArrowUp";
    case GLFW_KEY_DOWN: return "ArrowDown";
    case GLFW_KEY_HOME: return "Home";
    case GLFW_KEY_END: return "End";
    default: return null;
    }
}
