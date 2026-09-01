module vibe_search.desktop.main;

import std.stdio;
import dui;
import vibe_search.desktop.app_ui;
import vibe_search.desktop.window_host;

void main()
{
    writeln("vibe-search-desktop — dui/dew host");

    AppModel model = AppModel("./models/clip-v1.gguf");
    DuiApp app;
    model.bind(app);

    app.init((ref UiBuilder ui) => model.buildRoot(ui));

    version (Windows)
        runDesktopWindow(app, "Semantic Image Search");
    else version (linux)
        runDesktopWindow(app, "Semantic Image Search");
    else
    {
        stderr.writeln("Desktop window host is not wired for this platform yet.");
        app.dew.backend = new SoftwareBackend(960, 720);
        app.dew.resize(960, 720);
        app.frame();
    }
}
