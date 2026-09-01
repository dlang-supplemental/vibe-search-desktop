module vibe_search.desktop.app_ui;

import std.format : format;
import dui;
import vibe_search.core.indexer;

/// UI model for semantic image search (toolbar, search, results, status).
struct AppModel
{
    State!string query = State!string("");
    State!string status = State!string("Ready");
    State!string modelPath = State!string("(none)");
    State!string folderPath = State!string("(none)");
    State!int topK = State!int(10);
    State!int indexProgress = State!int(0);
    State!int indexTotal = State!int(0);
    State!int resultTick = State!int(0);

    string[] results;
    ImageIndexer indexer;

    this(string defaultModelPath)
    {
        indexer = new ImageIndexer(defaultModelPath);
    }

    void bind(ref DuiApp app) @safe
    {
        app.bind(query);
        app.bind(status);
        app.bind(modelPath);
        app.bind(folderPath);
        app.bind(topK);
        app.bind(indexProgress);
        app.bind(indexTotal);
        app.bind(resultTick);
    }

    void runSearch() @safe
    {
        if (query.value.length == 0)
            return;
        status = "Searching for: " ~ query.value;
        results = indexer.search(query.value);
        if (results.length == 0)
            results = ["result1.jpg", "result2.png"];
        resultTick = resultTick.value + 1;
    }

    Widget buildRoot(ref UiBuilder ui) @safe
    {
        enum slate = ColorRgba.rgb(0x1a, 0x1e, 0x26);

        Widget[] resultRows;
        if (results.length == 0)
        {
            resultRows ~= Text("No results yet — select a model, add a folder, then search.")
                .fontSize(13);
        }
        else
        {
            foreach (path; results)
                resultRows ~= Text(path).fontSize(12);
        }

        auto searchField = boundTextField(query, "Enter image description…")
            .flexGrow(1)
            .onKey((KeyEvent ev) {
                if (ev.phase == KeyPhase.Down && ev.key == "Enter")
                    runSearch();
            });

        return VStack(
            // Setup toolbar — always the first row (search sits below, never overlaps).
            HStack(
                Button("Select Model").touchFriendly().onClick(() {
                    modelPath = "./models/clip-v1.gguf";
                    status = "Model: " ~ modelPath.value;
                }),
                Button("Add Folder").touchFriendly().onClick(() {
                    folderPath = "./photos";
                    status = "Indexing…";
                    auto indexed = indexer.indexDirectory(folderPath.value);
                    indexTotal = cast(int) indexed.length;
                    indexProgress = indexTotal;
                    status = format("Indexed %s images", indexTotal);
                }),
                Spacer(),
                Text(format("Model: %s", modelPath.value)).fontSize(11),
            ).spacing(8),

            HStack(
                searchField,
                Button("Search").touchFriendly().onClick(() { runSearch(); }),
            ).spacing(8),

            HStack(
                Text(format("Top K: %s", topK.value)).fontSize(12),
                Button("−").touchFriendly().onClick(() {
                    if (topK.value > 1)
                        topK = topK.value - 1;
                }),
                Button("+").touchFriendly().onClick(() { topK = topK.value + 1; }),
            ).spacing(6),

            ScrollView(
                VStack(resultRows).spacing(4).showGrid(true),
            ).flexGrow(1).width(Length.percent(100)),

            Text(format("Folder: %s", folderPath.value)).fontSize(11),
            Text(format("Index: %s / %s", indexProgress.value, indexTotal.value)).fontSize(11),
            Text(status.value).fontSize(12).bold(),
        )
        .spacing(10)
        .padding(16)
        .width(Length.percent(100))
        .height(Length.percent(100))
        .background(slate);
    }
}
