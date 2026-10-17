module tests.coord.common;

import daemon.coord : Entry;

string[] texts(Entry[] entries)
{
    string[] ret = new string[0];
    foreach (entry; entries)
        ret ~= entry.text;

    return ret;
}
