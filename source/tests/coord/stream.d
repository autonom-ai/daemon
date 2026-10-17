module tests.coord.stream;

import daemon.coord : Entry, Stream;
import tests.common : Fixture;
import tests.coord.common : texts;

import unit_threaded : Name, should, shouldThrow;

import std.array : replicate;
import std.conv : to;
import std.file : exists, write, readText, symlink, getSize;
import std.path : buildPath;
import std.string : splitLines;

@Name("Coordination stream rotates on-disk log when line count reaches maxStreamEntries")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_stream.jsonl");
    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 5);

    foreach (i; 0..5)
        stream.append(Entry.create("wren", "e"~i.to!string));

    exists(path).should == true;
    exists(path~".1").should == false;
    stream.entries.length.should == 5;

    stream.append(Entry.create("wren", "e5"));
    exists(path~".1").should == true;
    exists(path).should == true;
    stream.entries.length.should == 5;
    stream.since(0).length.should == 5;
    stream.since(0)[0].text.should == "e1";
    stream.since(0)[4].text.should == "e5";

    string rotatedContent = readText(path~".1");
    rotatedContent.splitLines().length.should == 5;

    string activeContent = readText(path);
    activeContent.splitLines().length.should == 1;
}

@Name("Coordination stream rotates on-disk log when file size reaches maxStreamBytes")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_size_stream.jsonl");
    Stream stream = new Stream("test", path, 400, 100);

    string payload = replicate("A", 150);
    foreach (i; 0..5)
        stream.append(Entry.create("wren", payload~i.to!string));

    exists(path~".1").should == true;
    (getSize(path~".1") <= 800).should == true;
    (getSize(path) <= 800).should == true;
    stream.entries.length.should == 5;
}

@Name("Coordination stream reconstructs tail window across reload after rotation")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_reload_stream.jsonl");
    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 5);

    foreach (i; 0..7)
        stream.append(Entry.create("wren", "m"~i.to!string));

    exists(path~".1").should == true;

    Stream reloaded = new Stream("test", path, 4 * 1024 * 1024, 5);
    reloaded.entries.length.should == 5;
    texts(reloaded.entries).should == ["m2", "m3", "m4", "m5", "m6"];
}

@Name("Coordination stream rejects rotation if destination is a symlink")
unittest
{
    Fixture fixture = Fixture.create();
    scope(exit)
        fixture.close();

    string path = buildPath(fixture.root, "test_symlink_stream.jsonl");
    string rotated = path~".1";
    string target = buildPath(fixture.root, "outside.jsonl");
    write(target, "secret");

    Stream stream = new Stream("test", path, 4 * 1024 * 1024, 2);
    stream.append(Entry.create("wren", "first"));
    stream.append(Entry.create("wren", "second"));

    symlink(target, rotated);
    stream.append(Entry.create("wren", "third")).shouldThrow!Exception();
    readText(target).should == "secret";
}
