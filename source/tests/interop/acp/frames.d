module tests.interop.acp.frames;

import daemon.interop.acp.frames;

import unit_threaded;

import std.array : replicate;
import std.json : JSONValue, parseJSON;

@Name("ACP frames preserve extension fields and distinguish string and numeric identities")
unittest
{
    JSONValue original = parseJSON(`{"jsonrpc":"2.0","id":"1","method":"extension/test","params":{"body":"a\\nb"},"_meta":{"unknown":true}}`);
    Frame frame = Frame(original);
    FrameReader reader;
    Frame[] received;
    string line = frame.encode();
    foreach (character; line)
        reader.feed(cast(const(ubyte)[])[character], (Frame value) { received ~= value; });
    reader.finish();
    received.length.should == 1;
    received[0].value.should == original;
    (received[0].key != Frame(parseJSON(`{"jsonrpc":"2.0","id":1,"result":{}}`)).key).should == true;
}

@Name("ACP frame input rejects oversized frames before retaining another byte")
@ShouldFailWith!Exception
unittest
{
    FrameReader reader;
    reader.feed(cast(const(ubyte)[])"x".replicate(FRAME_LIMIT + 1), (Frame value) {});
}

@Name("ACP frame input rejects a stream ending inside a frame")
@ShouldFailWith!Exception
unittest
{
    FrameReader reader;
    reader.feed(cast(const(ubyte)[])`{"jsonrpc":"2.0"`, (Frame value) {});
    reader.finish();
}
